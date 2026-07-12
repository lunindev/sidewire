import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import Network
import SidewireProtocol
import SidewireCore

/// Source role: discovers Displays, connects (via the self-healing Reconnector), and
/// drives virtual-display → capture → encode → session, plus injects incoming input.
/// @MainActor for SwiftUI observation. Session callbacks self-hop to main.
@MainActor
final class SourceController: ObservableObject {
    let discovery = Discovery()
    let capture = ScreenCapture()
    let virtualDisplay = VirtualDisplayManager()
    let interfaceMonitor = InterfaceMonitor()

    /// "" = Auto (let macOS choose). Otherwise the interface name to pin the connection to.
    @Published var selectedInterfaceName: String = UserDefaults.standard.string(forKey: "sidewire.interface") ?? "" {
        didSet { UserDefaults.standard.set(selectedInterfaceName, forKey: "sidewire.interface") }
    }
    private var selectedInterface: NWInterface? {
        interfaceMonitor.interfaces.first { $0.name == selectedInterfaceName }?.nwInterface
    }

    private let injector = InputInjector()
    private var encoder: VideoEncoder?
    private var reconnector: Reconnector?
    private weak var activeSession: Session?
    /// The current link's session (set as soon as it's created, before it's ready), so an
    /// auth/keyChanged failure can drop the stale pin by the peer's TLS-observed device id even
    /// on a manual-IP connect that carries no expected-peer id.
    private weak var currentSession: Session?
    private var pendingConfig: Config?
    private var firstEncodedLogged = false

    // D3 — "Reconnect to apply". The active link bakes in the quality settings that were current
    // when it dialed; when the live settings drift, Settings offers a reconnect. We keep the
    // transport factory so we can re-dial the same peer with a fresh settings snapshot.
    private var currentMakeTransport: (() -> TCPTransport)?
    /// The peer device id this link expects (a paired peer, for keyChanged enforcement), or nil
    /// for a first-time pairing / manual-IP connect. On a fatal auth/keyChanged we forget it so
    /// the next connect re-pairs cleanly (avoids a skip-proof ↔ reject standoff after one side
    /// forgets the pin).
    private var currentExpectedPeerId: String?
    /// The quality settings the current link is using. nil when no link is up. When it differs
    /// from live AppSettings, the Settings pane shows "Changes apply on reconnect".
    @Published private(set) var activeQuality: QualitySnapshot?

    // Source-side monitor: static-screen keep-alive + encoder-stall watchdog.
    private var monitorTimer: Timer?
    private var encodedSinceCheck = 0
    private var ticksSinceEncoded = 0
    private var lastKeyframe: Data?
    private var encoderStallStrikes = 0
    /// Counts monitor ticks so the Accessibility poll runs ~every 5s (10 × keepAliveInterval),
    /// not on every 0.5s keep-alive tick.
    private var axCheckTicks = 0

    // Reconnect give-up thresholds. We never truly stop reconnecting (the peer may come back),
    // but after enough attempts the message becomes a stronger "is it even running?" hint.
    private let reconnectHintAfter = 10
    /// A launch-time auto-connect to a stale lastHost must not loop forever; give up after this
    /// many attempts (the setting itself stays on — a manual connect still works).
    static let maxAutoConnectAttempts = 3
    /// True while the current link was started by launch auto-connect (bounded retries).
    private var autoConnecting = false

    // Adaptive bitrate (RTT-driven congestion control).
    private var currentBitrate = 30_000_000
    private var rttBaseline: Double = 0
    private var rampClearTicks = 0
    private let minBitrate = 5_000_000
    private var maxBitrate = 50_000_000 // ceiling; set from AppSettings when a link starts
    @Published var currentBitrateMbps: Double = 0

    @Published var needsScreenRecording = false
    /// Set when Accessibility is revoked mid-session: video keeps streaming but remote input
    /// is disabled until the grant returns (polled while streaming, recovers automatically).
    @Published var accessibilityRevoked = false
    @Published var localThunderboltIP: String?
    /// The PIN shown on the Display, entered here to derive the TLS-PSK key. Persisted so
    /// it's entered once.
    @Published var pairingPIN: String = UserDefaults.standard.string(forKey: "sidewire.enteredPIN") ?? "" {
        didSet { UserDefaults.standard.set(pairingPIN, forKey: "sidewire.enteredPIN") }
    }
    @Published var peers: [DiscoveredPeer] = []
    /// True when discovery has been stuck (browser `.waiting`/`.failed`) with no peers found for
    /// a few seconds — most often a denied Local Network permission. Drives a stronger inline
    /// hint next to "Searching…" (backlog C1). Best-effort: cleared the moment a peer appears.
    @Published var discoveryLikelyBlocked = false
    @Published var statusText = String(localized: "Idle")
    /// Set when the last connect attempt failed the TLS-PSK handshake (wrong PIN). Drives a
    /// clear message in the UI instead of an endless silent "Reconnecting…". Cleared on the
    /// next connect attempt / disconnect.
    @Published var pinRejected = false
    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var isConnecting = false
    @Published var peerName: String?
    @Published var rttMs: Double = 0
    @Published var connectionInterface = ""

    private var wakeObserver: Any?
    /// Bumped whenever the discovery-waiting state flips, to invalidate a pending debounce check.
    private var discoveryWaitGeneration = 0
    /// Bumped per link (startLink). A retired reconnector's late `.stopped`/`.reconnecting`
    /// callback carries the old generation and is ignored — important for D3's reconnect, which
    /// tears down and re-dials back-to-back so the new reconnector exists before the old one's
    /// stop() emits `.stopped`.
    private var linkGeneration = 0

    init() {
        discovery.onPeersChanged = { [weak self] peers in
            Task { @MainActor in
                guard let self else { return }
                self.peers = peers
                if !peers.isEmpty { self.discoveryLikelyBlocked = false } // found something → not blocked
            }
        }
        discovery.onWaiting = { [weak self] waiting in
            Task { @MainActor in self?.handleDiscoveryWaiting(waiting) }
        }
        virtualDisplay.onActivated = { [weak self] did in
            Task { @MainActor in self?.beginStreaming(displayID: did) }
        }
        // A capture death (SCStream error) is not a static screen — force a reconnect.
        capture.onStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isStreaming else { return }
                Log.media.notice("capture stopped (\(error.localizedDescription)) → reconnect")
                self.activeSession?.close(reason: SessionConstants.captureStallReason)
            }
        }
        // On wake, force an immediate reconnect AND rebuild the virtual display (fragile
        // across sleep) rather than reuse a possibly-invalidated one.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.reconnector != nil else { return }
                Log.source.notice("woke from sleep → rebuilding")
                self.virtualDisplay.destroy()
                self.activeSession?.close(reason: SessionConstants.wakeReason)
            }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func startDiscovery() {
        // React to interface changes live: drop a persisted selection that has gone away, and
        // refresh the Thunderbolt hint the instant a cable is plugged/unplugged (previously
        // only a manual Refresh updated it).
        interfaceMonitor.onInterfacesChanged = { [weak self] in self?.validateSelectedInterface() }
        interfaceMonitor.onThunderboltIPChanged = { [weak self] ip in self?.localThunderboltIP = ip }
        interfaceMonitor.start()
        localThunderboltIP = InterfaceMonitor.localThunderboltIP()
        discovery.start()
    }
    func stopDiscovery() { discovery.stop() }

    /// Re-scan the network for Displays.
    func refreshDiscovery() {
        peers = []
        discoveryLikelyBlocked = false // give the fresh scan a clean slate before re-flagging
        localThunderboltIP = InterfaceMonitor.localThunderboltIP()
        discovery.stop()
        discovery.start()
    }

    /// Debounced handling of the discovery browser stalling. A brief `.waiting` at startup is
    /// normal, so only flag a likely block (usually Local Network denied) if the browser is
    /// STILL waiting with nothing found a few seconds later. Cleared immediately when it recovers.
    private func handleDiscoveryWaiting(_ waiting: Bool) {
        discoveryWaitGeneration += 1
        guard waiting else { discoveryLikelyBlocked = false; return }
        let gen = discoveryWaitGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.discoveryWaitGeneration == gen, self.peers.isEmpty else { return }
            self.discoveryLikelyBlocked = true
        }
    }

    /// If the persisted interface selection no longer exists among the current interfaces,
    /// revert to Auto and persist the clearing so the Picker doesn't show a dangling choice.
    /// Guarded on a non-empty list so a transient empty update at startup can't wrongly clear.
    private func validateSelectedInterface() {
        guard !selectedInterfaceName.isEmpty, !interfaceMonitor.interfaces.isEmpty else { return }
        if !interfaceMonitor.interfaces.contains(where: { $0.name == selectedInterfaceName }) {
            Log.source.notice("persisted interface '\(self.selectedInterfaceName, privacy: .public)' no longer present → reverting to Auto")
            selectedInterfaceName = "" // didSet persists the clearing
        }
    }

    /// If enabled in Settings, dial the last IP on launch (using the saved PIN). No-op if
    /// disabled, already connecting, missing a PIN, or without a remembered address.
    func maybeAutoConnect() {
        guard AppSettings.shared.autoConnectLastPeer,
              reconnector == nil, !isConnected, !isConnecting,
              pairingPIN.count == 6 else { return }
        let host = SourceController.lastHost
        guard !host.isEmpty else { return }
        Log.source.info("auto-connecting to last peer \(host, privacy: .public)")
        connect(host: host)
        autoConnecting = true // connect() cleared it; mark this link as the bounded auto-attempt
    }

    func connect(to peer: DiscoveredPeer) {
        autoConnecting = false // an explicit user connect is unbounded
        let iface = selectedInterface
        let identity = LocalIdentity.shared
        // If this peer is already paired, enforce public-key pinning against its advertised
        // device id (a changed key → "keyChanged"). Unpaired ⇒ nil (accept any key, pair via PIN).
        let expected = pinnedExpectation(for: peer.deviceId)
        startLink(peerName: peer.name, expectedPeerId: expected) {
            TCPTransport(endpoint: peer.endpoint, interface: iface, identity: identity,
                         expectedPeerDeviceId: expected)
        }
    }

    func connect(host: String, port: UInt16 = ProtocolConstants.fallbackPort) {
        autoConnecting = false // an explicit user connect is unbounded (maybeAutoConnect re-sets it)
        let iface = selectedInterface
        let identity = LocalIdentity.shared
        // Manual IP has no advertised device id, so key pinning can't be pre-enforced here (the
        // peer's key is still verified against the trust store post-handshake by the Session).
        // Remember the last IP dialed by hand so the field is pre-filled next launch — the
        // Thunderbolt link-local address is stable per cable and tedious to retype.
        UserDefaults.standard.set(host, forKey: SourceController.lastHostKey)
        startLink(peerName: host, expectedPeerId: nil) {
            TCPTransport(host: host, port: port, interface: iface, identity: identity)
        }
    }

    /// The device id to enforce (keyChanged) for a discovered peer: its advertised id, but only
    /// if we have already pinned it. nil for an unknown/unpaired peer (first-time pairing).
    private func pinnedExpectation(for advertisedId: String?) -> String? {
        guard let advertisedId, KeychainTrustStore.shared.pinned(for: advertisedId) != nil else { return nil }
        return advertisedId
    }

    static let lastHostKey = "sidewire.lastHost"
    static var lastHost: String { UserDefaults.standard.string(forKey: lastHostKey) ?? "" }

    func disconnect() {
        reconnector?.stop()
        reconnector = nil
        activeSession = nil
        tearDownEncoderCapture()
        virtualDisplay.destroy()
        pendingConfig = nil
        activeQuality = nil
        currentMakeTransport = nil
        currentExpectedPeerId = nil
        isConnected = false
        isConnecting = false
        isStreaming = false
        pinRejected = false
        autoConnecting = false
        accessibilityRevoked = false
        injector.injectionEnabled = true
        statusText = String(localized: "Disconnected")
        peerName = nil
        rttMs = 0
        connectionInterface = ""
        Log.event(.source, "disconnected")
    }

    /// D3 — tear down the current link and immediately re-dial the same peer, so quality changes
    /// (codec/resolution/fps/bitrate/scale) that only apply on the next connection take effect
    /// now. No-op if nothing is connected. `startLink` re-snapshots the live AppSettings.
    func reconnectWithCurrentSettings() {
        guard let make = currentMakeTransport else { return }
        let name = peerName ?? String(localized: "the last Mac")
        let expected = currentExpectedPeerId
        Log.event(.source, "reconnecting to apply new quality settings")
        disconnect() // clears currentMakeTransport — hence the local capture above
        startLink(peerName: name, expectedPeerId: expected, makeTransport: make)
    }

    // MARK: - Connection

    private func startLink(peerName: String, expectedPeerId: String?,
                           makeTransport: @escaping () -> TCPTransport) {
        guard reconnector == nil else { return } // ignore re-entrant connects
        pinRejected = false // fresh attempt clears any prior wrong-PIN error
        self.peerName = peerName
        self.currentExpectedPeerId = expectedPeerId
        // Remember the transport factory so D3's reconnect can re-dial the same peer.
        currentMakeTransport = makeTransport
        linkGeneration &+= 1
        let gen = linkGeneration
        Log.event(.source, "connecting to \(peerName)")

        // One stable HELLO (and sessionId) reused across reconnect attempts — idempotent
        // resume. Built here on the main actor (capabilities read NSScreen).
        let hello = DeviceIdentity.makeHello(role: .source, sessionId: UUID().uuidString)
        // Snapshot settings on the main actor; makeSession runs on the reconnector queue.
        let settings = AppSettings.shared
        activeQuality = QualitySnapshot(settings) // D3: what this link is using
        let dims = settings.resolutionPreset.dimensions
        let codecPref = settings.codec.forced
        let fpsCap = settings.maxFps
        let maxBps = settings.maxBitrateBps
        let hiDPIPref = settings.virtualDisplayScale.forcedHiDPI
        maxBitrate = maxBps // ceiling for RTT-driven adaptation
        // Pairing: the entered PIN + the Keychain trust store, snapshotted for the session queue.
        let pin = pairingPIN

        let reconnector = Reconnector(makeSession: {
            let s = Session(transport: makeTransport(), role: .source, localHello: hello)
            s.preferredDimensions = dims
            s.preferredCodec = codecPref
            s.preferredMaxFps = fpsCap
            s.preferredMaxBitrateBps = maxBps
            s.preferredHiDPI = hiDPIPref
            s.pairingConfig = PairingConfig(pin: pin, trustStore: KeychainTrustStore.shared)
            return s
        })
        self.reconnector = reconnector

        reconnector.onSession = { [weak self] session in
            // Called on the reconnector queue: wire media callbacks (they self-hop to main).
            Task { @MainActor in self?.currentSession = session }
            session.onPaired = { peer in
                Task { @MainActor in
                    Log.source.info("paired with Display \(peer.deviceId)")
                    NotificationCenter.default.post(name: .sidewirePairedPeersChanged, object: nil)
                }
            }
            session.onReady = { [weak self, weak session] config in
                Task { @MainActor in
                    guard let self, let session else { return }
                    self.onSessionReady(session, config: config)
                }
            }
            session.onDisplayInfo = { info in
                Log.source.info("Display native \(info.width)x\(info.height) @\(info.scaleFactor)x")
            }
            session.onInputEvent = { [weak self] rec in
                self?.injector.inject(event: rec) // CGEvent post is fine off-main
            }
            session.onRequestIDR = { [weak self] in
                // A decoder rebuild has no reference frames or parameter sets, so recovery
                // must be a full keyframe. (LTR-P refresh needs a decoder-state-aware NACK
                // and only pays off on a lossy transport — deferred to the QUIC path.)
                Task { @MainActor in self?.encoder?.forceKeyframe() }
            }
            session.onRTT = { [weak self] rtt in
                Task { @MainActor in self?.rttMs = rtt }
            }
            session.onInterface = { [weak self] label in
                Task { @MainActor in self?.connectionInterface = label }
            }
        }
        reconnector.onState = { [weak self] state in
            // Ignore callbacks from a retired reconnector (D3 reconnect re-dials before the old
            // one's stop() emits `.stopped`).
            Task { @MainActor in
                guard let self, self.linkGeneration == gen else { return }
                self.applyLinkState(state)
            }
        }
        reconnector.start()
    }

    private func applyLinkState(_ state: Reconnector.LinkState) {
        guard reconnector != nil else { return } // ignore late callbacks after disconnect()
        switch state {
        case .connecting:
            isConnecting = true; isConnected = false; statusText = String(localized: "Connecting…")
            Log.event(.source, "link: connecting")
        case .streaming:
            isConnecting = false; isConnected = true; statusText = String(localized: "Connected")
            autoConnecting = false // reached a live stream → the auto-attempt succeeded
            Log.event(.source, "link: connected")
        case .reconnecting(let attempt):
            // A launch auto-connect to a stale lastHost must not loop forever on every launch:
            // after a few attempts, give up this attempt (the setting stays on for next time).
            if autoConnecting && attempt >= Self.maxAutoConnectAttempts {
                Log.event(.source, "auto-connect gave up after \(attempt) attempts", level: .notice)
                let name = peerName ?? String(localized: "the last Mac")
                disconnect()
                statusText = String(localized: "Couldn't reach \(name). Connect manually.")
                return
            }
            // The session died; drop the encoder/capture but KEEP the virtual display so
            // window layout survives and reconnection is fast.
            isConnected = false; isConnecting = true; isStreaming = false
            // After many attempts, swap the counter for a "is it even running?" hint (still
            // retrying); a Cancel affordance in SourceView maps to the disconnect path.
            statusText = attempt >= reconnectHintAfter
                ? String(localized: "Still trying — is Sidewire running on the other Mac?")
                : String(localized: "Reconnecting (\(attempt))…")
            Log.event(.source, "link: reconnecting (attempt \(attempt))")
            tearDownEncoderCapture()
        case .failed(let reason):
            // Terminal (protocol/role mismatch, wrong PIN, key changed, rate-limited, or displaced
            // by another Source): tear down and release the reconnector so a fresh connect() can
            // proceed.
            isConnecting = false; isConnected = false
            // pinRejected drives a dedicated field-level hint; the human status copy for every
            // reason (auth/keyChanged/rateLimited/superseded included) lives once in CloseReasonText.
            if reason == SessionConstants.authFailureReason { pinRejected = true }
            // On a wrong PIN or a changed key, drop any stale pin so the next connect runs a fresh
            // PIN proof instead of skipping it and being refused again. Prefer the expected-peer id
            // (discovery path); fall back to the peer's TLS-observed id so a manual-IP connect
            // heals too (it carries no expected id).
            if reason == SessionConstants.authFailureReason || reason == SessionConstants.keyChangedReason,
               let stale = currentExpectedPeerId ?? currentSession?.peerDeviceId {
                KeychainTrustStore.shared.forget(stale)
                NotificationCenter.default.post(name: .sidewirePairedPeersChanged, object: nil)
            }
            statusText = CloseReasonText.source(reason)
            Log.event(.source, "link: failed (\(reason))", level: .notice)
            // Mirror disconnect(): a stale revocation banner (and disabled injection) must not
            // survive into the next link — the monitor that would clear it stops below.
            accessibilityRevoked = false
            injector.injectionEnabled = true
            tearDownEncoderCapture()
            virtualDisplay.destroy()
            activeSession = nil
            pendingConfig = nil
            reconnector = nil
            autoConnecting = false
            activeQuality = nil
            currentMakeTransport = nil
            currentExpectedPeerId = nil
        case .stopped:
            isConnecting = false; isConnected = false; statusText = String(localized: "Disconnected")
        }
    }

    private func onSessionReady(_ session: Session, config: Config) {
        guard reconnector != nil else { return } // stale callback from a torn-down link
        activeSession = session
        peerName = session.peerName
        pendingConfig = config
        prepareStreaming(config: config)
    }

    private func prepareStreaming(config: Config) {
        let hiDPI = config.hiDPI ?? true
        // Keep the virtual display alive if it already matches the negotiated size AND scale.
        if virtualDisplay.isActive,
           virtualDisplay.width == UInt(config.width),
           virtualDisplay.height == UInt(config.height),
           virtualDisplay.hiDPI == hiDPI,
           let did = virtualDisplay.virtualDisplayID {
            beginStreaming(displayID: did)
        } else {
            statusText = String(localized: "Creating display…")
            Log.event(.media, "creating virtual display \(config.width)x\(config.height) hiDPI=\(hiDPI)")
            virtualDisplay.recreate(width: UInt(config.width), height: UInt(config.height), hiDPI: hiDPI)
        }
    }

    private func beginStreaming(displayID: CGDirectDisplayID) {
        guard reconnector != nil, let config = pendingConfig, let session = activeSession else { return }

        // Gate on Screen Recording: without it ScreenCaptureKit produces no frames, the
        // receiver tears down, and we'd loop forever re-triggering the TCC prompt. Stop
        // the loop and tell the user instead.
        guard CGPreflightScreenCaptureAccess() else {
            Log.event(.media, "Screen Recording NOT granted for this build → cannot capture; stopping (grant it + relaunch)", level: .error)
            needsScreenRecording = true
            _ = CGRequestScreenCaptureAccess() // register the app / prompt once
            disconnect()
            statusText = String(localized: "Grant Screen Recording, then reconnect")
            return
        }
        needsScreenRecording = false

        // Clear any wiring bound to a previous session, but do NOT stop capture here —
        // the ordered stop→start below owns that so the two never race.
        stopMonitor()
        encoder?.invalidate()
        encoder = nil
        isStreaming = false
        injector.virtualDisplayID = displayID
        firstEncodedLogged = false
        Log.event(.media, "virtual display \(displayID) active → starting capture \(config.width)x\(config.height)@\(config.fps) codec=\(config.codec)")

        let enc = makeEncoder(config: config, session: session)
        statusText = String(localized: "Streaming")
        startMonitor()
        Task { [weak self] in
            // Ordered: always stop a prior stream before starting, so startCapture never
            // no-ops against a still-running capture (which would leave "streaming" with
            // no frames).
            await self?.capture.stopCapture()
            await self?.capture.startCapture(displayID: displayID, fps: config.fps,
                                             pixelWidth: config.width, pixelHeight: config.height)
            await MainActor.run {
                guard let self, self.encoder === enc else { return } // stale completion after teardown
                self.isStreaming = true
            }
        }
    }

    /// Create an encoder wired to the current session + capture. Reused by beginStreaming
    /// and the encoder-stall recovery path.
    @discardableResult
    private func makeEncoder(config: Config, session: Session) -> VideoEncoder {
        let enc = VideoEncoder(width: Int32(config.width), height: Int32(config.height),
                               codec: VideoCodec(rawValue: config.codec) ?? .hevc,
                               fps: config.fps, bitrate: config.bitrateStartBps)
        encoder = enc
        currentBitrate = config.bitrateStartBps
        currentBitrateMbps = Double(currentBitrate) / 1_000_000
        rttBaseline = 0
        rampClearTicks = 0
        enc.forceKeyframe()
        enc.onEncodedFrame = { [weak self, weak session] data, isKey, ltrToken, ptsNanos in
            Task { @MainActor in
                guard let self else { return }
                self.encodedSinceCheck += 1
                if isKey { self.lastKeyframe = data }
                if !self.firstEncodedLogged {
                    self.firstEncodedLogged = true
                    Log.media.info("first frame ENCODED (\(data.count) bytes, key=\(isKey)) → sending")
                }
            }
            session?.sendVideo(data, keyframe: isKey, ltrToken: ltrToken, ptsNanos: ptsNanos)
        }
        capture.setSampleHandler { [weak enc] sampleBuffer in
            guard let pb = sampleBuffer.imageBuffer else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            enc?.encode(pixelBuffer: pb, presentationTime: pts)
        }
        return enc
    }

    private func startMonitor() {
        stopMonitor()
        encodedSinceCheck = 0
        encoderStallStrikes = 0
        ticksSinceEncoded = 0
        axCheckTicks = 0
        monitorTimer = Timer.scheduledTimer(withTimeInterval: SessionConstants.keepAliveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.monitorTick() }
        }
    }

    private func stopMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    /// Runs every keepAliveInterval while streaming. Distinguishes a legitimately static
    /// screen (send a keep-alive keyframe so the receiver's no-frame watchdog isn't fooled)
    /// from a wedged encoder (capture is delivering but no output for ~1s → recreate;
    /// escalate to reconnect if it recurs).
    private func monitorTick() {
        // Poll Accessibility ~every 5s (10 × keepAliveInterval). Revocation silently kills
        // CGEvent injection, so we detect it and surface it; done before the streaming guard
        // so it ticks throughout the session.
        axCheckTicks += 1
        if axCheckTicks >= 10 { axCheckTicks = 0; checkAccessibilityGrant() }

        guard isStreaming, let config = pendingConfig, let session = activeSession else { return }
        adaptBitrate()
        let encoded = encodedSinceCheck
        encodedSinceCheck = 0
        if encoded > 0 { encoderStallStrikes = 0; ticksSinceEncoded = 0; return }
        ticksSinceEncoded += 1

        // Feed the receiver on EVERY idle tick, the instant fresh frames stop — do NOT wait
        // for the lagging 1s capture.fps to decay first. That ~1s gap after each active→static
        // transition is exactly what starved the receiver's no-frame watchdog and flashed
        // "Reconnecting…" (with showsCursor=false a still screen delivers zero frames, so the
        // keep-alive is the ONLY thing keeping the receiver fed). Resending the last keyframe
        // holds the last image with no visible gap.
        if let keyframe = lastKeyframe {
            session.sendVideo(keyframe, keyframe: true)
        } else {
            encoder?.forceKeyframe() // cold start: nothing cached yet → generate a keyframe
        }

        // Encoder-stall detection (capture IS delivering frames but the encoder emits nothing)
        // is a genuinely wedged encoder — meaningful only while capture actually produces
        // frames. capture.fps is a lagging 1s average, so require it >2 AND persisting ~1s
        // before acting, and clear strikes once the screen is truly static so intermittent
        // activity can never accumulate a false "encoder-stall" reconnect.
        if capture.fps > 2 {
            guard ticksSinceEncoded >= 2 else { return }
            ticksSinceEncoded = 0
            encoderStallStrikes += 1
            Log.media.notice("encoder stall (\(self.encoderStallStrikes)) — capture fps=\(self.capture.fps) but 0 encoded")
            if encoderStallStrikes >= SessionConstants.encoderStallEscalate {
                encoderStallStrikes = 0
                session.close(reason: SessionConstants.encoderStallReason) // escalate → reconnect rebuilds everything
            } else {
                encoder?.invalidate()
                makeEncoder(config: config, session: session)
            }
        } else {
            encoderStallStrikes = 0 // truly static (capture idle) → not a stall
        }
    }

    /// Detect Accessibility being revoked (or restored) mid-session. On revocation, disable
    /// injection — CGEvent posts would silently no-op — and surface a message while video keeps
    /// streaming; when the grant returns, re-enable automatically.
    private func checkAccessibilityGrant() {
        let trusted = Permissions.hasAccessibility
        if !trusted && !accessibilityRevoked {
            accessibilityRevoked = true
            injector.injectionEnabled = false
            Log.event(.source, "Accessibility revoked mid-session → remote input disabled (video continues)", level: .error)
        } else if trusted && accessibilityRevoked {
            accessibilityRevoked = false
            injector.injectionEnabled = true
            Log.event(.source, "Accessibility restored → remote input re-enabled", level: .notice)
        }
    }

    /// RTT-driven congestion control. On TCP there is no packet loss, so a rising RTT is
    /// the congestion signal (send buffers filling). Cut fast, ramp up cautiously.
    private func adaptBitrate() {
        guard let enc = encoder, rttMs > 0 else { return }
        // Track the "good" RTT as a minimum; only let it drift UP while the link is clear,
        // so sustained congestion can't raise the baseline and defeat its own detection.
        if rttBaseline == 0 || rttMs < rttBaseline { rttBaseline = rttMs }
        let congested = rttMs > max(rttBaseline * 2.5, rttBaseline + 40)
        if congested {
            rampClearTicks = 0
            let reduced = max(minBitrate, Int(Double(currentBitrate) * 0.8))
            if reduced != currentBitrate {
                currentBitrate = reduced
                enc.updateBitrate(currentBitrate)
                currentBitrateMbps = Double(currentBitrate) / 1_000_000
                Log.media.notice("congestion (RTT \(Int(self.rttMs))ms vs base \(Int(self.rttBaseline))ms) → \(self.currentBitrate / 1_000_000) Mbps")
            }
        } else {
            rttBaseline += (rttMs - rttBaseline) * 0.02 // drift up only when not congested
            rampClearTicks += 1
            if rampClearTicks >= 4 { // ~2s stable at 0.5s ticks
                rampClearTicks = 0
                let raised = min(maxBitrate, Int(Double(currentBitrate) * 1.1))
                if raised != currentBitrate {
                    currentBitrate = raised
                    enc.updateBitrate(currentBitrate)
                    currentBitrateMbps = Double(currentBitrate) / 1_000_000
                }
            }
        }
    }

    private func tearDownEncoderCapture() {
        stopMonitor()
        capture.setSampleHandler(nil)
        Task { await capture.stopCapture() }
        encoder?.flush()
        encoder?.invalidate()
        encoder = nil
        lastKeyframe = nil
        isStreaming = false
    }
}
