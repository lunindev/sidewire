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
    /// Out-of-band cursor feed: streams the pointer's position while it's over the virtual
    /// display so the Display can warp its native cursor there (no encode/decode lag on the
    /// pointer). Started in beginStreaming, stopped in tearDownEncoderCapture.
    private let cursorTracker = CursorTracker()
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
    /// When the current link entered reconnecting from a live stream. We keep the virtual display
    /// for a brief blip (fast reconnect, window layout survives), but once reconnection has been
    /// failing this long we tear the phantom desktop down so the cursor can't stray onto a screen
    /// with no Mac behind it. A later successful reconnect recreates the display from config.
    private var reconnectingSince: Date?
    private let phantomLingerSeconds: TimeInterval = 4
    /// A link that has never once connected must not retry forever; give up after this many
    /// attempts. Applies to any first connect — launch auto-connect, a peer picked from the list,
    /// and a hand-typed address alike (the setting itself stays on; a fresh connect still works).
    static let maxFirstConnectAttempts = 3

    /// How the current link was started. Only the give-up copy depends on it — the retry bound is
    /// `everEstablished`. It exists because "couldn't reach it" needs completely different advice
    /// for an address you typed, a Mac you picked off a list (which is demonstrably on the network
    /// and running Sidewire — it advertised itself), and a silent reconnect at launch.
    enum LinkOrigin { case autoConnect, discovered, manualAddress }
    private var linkOrigin: LinkOrigin = .discovered

    /// Whether THIS link ever completed a handshake and reached `.streaming`. It is the difference
    /// between "the link dropped" and "the link was never right": a session that got established
    /// and then broke (sleep, cable pull, wake) must self-heal forever, but one that never
    /// completed is a wrong address / a Mac that isn't running Sidewire / the wrong network — and
    /// retrying that forever is what turned one mistyped digit into a two-minute wait ending in a
    /// status that blamed the other Mac.
    ///
    /// Deliberately keyed on the handshake, not on the first video frame: reaching `.streaming`
    /// already proves the address, the PIN and the peer's identity, which is exactly what the
    /// bound is asking about. A frame that never arrives afterwards is the watchdog's problem.
    private var everEstablished = false

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
    /// True once discovery has run a while and still found nothing. Unlike `discoveryLikelyBlocked`
    /// this does NOT require the browser to be `.waiting`/`.failed` — the common causes (Sidewire
    /// not open on the other Mac, both Macs set to be the main one, different networks/VPN) leave a
    /// perfectly healthy browser with zero results, so a state keyed on browser trouble can never
    /// fire for them. This is what turns the forever-"Searching…" dead-end into real guidance.
    @Published var searchedAWhileEmpty = false
    private var discoveryEscalation: DispatchWorkItem?
    @Published var statusText = String(localized: "Idle")
    /// Set when the last connect attempt failed the TLS-PSK handshake (wrong PIN). Drives a
    /// clear message in the UI instead of an endless silent "Reconnecting…". Cleared on the
    /// next connect attempt / disconnect.
    @Published var pinRejected = false
    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var isConnecting = false
    @Published var peerName: String?

    /// Which peer or address the current link is for. There is only ever one link, so pairing this
    /// with `isConnecting`/`isConnected` tells each row and the address field its OWN state —
    /// instead of every one of them reading the same link-global bools, which is why, while
    /// connected, every row in the list used to read "Disconnect" and why an address connect (no
    /// row) left Disconnect nowhere at all. nil ⇒ no link; set in `startLink`, cleared on teardown.
    enum LinkTarget: Equatable {
        case peer(id: String)   // a discovered row (DiscoveredPeer.id)
        case address(String)    // a hand-typed / auto-connect host — belongs to no row
    }
    @Published private(set) var linkTarget: LinkTarget?

    /// The state of one discovered row: only the row that IS the current target is ever non-idle.
    enum RowState { case idle, connecting, connected }
    func rowState(forPeerId id: String) -> RowState {
        guard linkTarget == .peer(id: id) else { return .idle }
        if isConnected { return .connected }
        return isConnecting ? .connecting : .idle
    }

    /// True while the active link is a hand-typed/auto-connect address (so the address field, not a
    /// row, owns its Cancel/Disconnect). During a reconnect `isConnecting` is true and `isConnected`
    /// false, so this stays true across a blip.
    var addressLinkActive: Bool {
        if case .address = linkTarget { return isConnecting || isConnected }
        return false
    }

    /// There's a live link but no discovered row to host its Cancel/Disconnect: an address connect,
    /// or a peer discovery has since dropped from `peers`. Surfaces where a peer list alone can't —
    /// the menu bar has no address field, so without this a menu-bar-only session couldn't be
    /// ended from the menu at all.
    var activeLinkNeedsStandaloneControl: Bool {
        switch linkTarget {
        case .none: return false
        case .address: return true
        case .peer(let id): return !peers.contains { $0.id == id }
        }
    }
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
                if peers.isEmpty {
                    // A peer that appeared then left (slept/quit) must not strand the screen on
                    // "Searching…" — re-arm so guidance returns if it stays empty. onPeersChanged
                    // only fires on a real change, so this can't busy-loop on empty→empty.
                    self.armDiscoveryEscalation()
                } else {
                    self.discoveryLikelyBlocked = false // found something → not blocked
                    self.searchedAWhileEmpty = false    // …and not a dead-end
                }
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
        // A pending escalation is [weak self] so it can't touch a dead controller, but cancelling
        // it (and the browser) here keeps a role switch from leaving either running.
        discoveryEscalation?.cancel()
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
        armDiscoveryEscalation()
    }
    func stopDiscovery() { discovery.stop(); discoveryEscalation?.cancel() }

    /// Re-scan the network for Displays.
    func refreshDiscovery() {
        peers = []
        discoveryLikelyBlocked = false // give the fresh scan a clean slate before re-flagging
        searchedAWhileEmpty = false
        localThunderboltIP = InterfaceMonitor.localThunderboltIP()
        discovery.stop()
        discovery.start()
        armDiscoveryEscalation()
    }

    /// After a grace period with no peers, surface real guidance instead of a perpetual "Searching…".
    private func armDiscoveryEscalation() {
        discoveryEscalation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.peers.isEmpty else { return }
            self.searchedAWhileEmpty = true
        }
        discoveryEscalation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
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
        Log.source.info("auto-connecting to last peer \(host, privacy: .public):\(SourceController.lastPort)")
        connect(host: host, port: SourceController.lastPort)
        linkOrigin = .autoConnect // connect() set .manualAddress; this dial is the silent launch attempt
    }

    /// Connect to a peer from the discovered list. `forceThunderbolt` dials the peer's advertised
    /// cable IP instead of its mDNS endpoint (the old green "Thunderbolt" quick-connect button),
    /// but the link is still tagged with the peer's identity so its row — not the address field —
    /// owns the connection, and key pinning is still enforced (the host transport carries the
    /// expected device id too, which the previous host-based dial silently dropped).
    func connect(to peer: DiscoveredPeer, forceThunderbolt: Bool = false) {
        linkOrigin = .discovered
        let iface = selectedInterface
        let identity = LocalIdentity.shared
        // If this peer is already paired, enforce public-key pinning against its advertised
        // device id (a changed key → "keyChanged"). Unpaired ⇒ nil (accept any key, pair via PIN).
        let expected = pinnedExpectation(for: peer.deviceId)
        let makeTransport: () -> TCPTransport
        if forceThunderbolt, let tb = peer.thunderboltIP {
            let port = peer.port ?? ProtocolConstants.fallbackPort
            makeTransport = {
                TCPTransport(host: tb, port: port, interface: iface, identity: identity,
                             expectedPeerDeviceId: expected)
            }
        } else {
            makeTransport = {
                TCPTransport(endpoint: peer.endpoint, interface: iface, identity: identity,
                             expectedPeerDeviceId: expected)
            }
        }
        startLink(peerName: peer.name, target: .peer(id: peer.id),
                  expectedPeerId: expected, makeTransport: makeTransport)
    }

    func connect(host: String, port: UInt16 = ProtocolConstants.fallbackPort) {
        linkOrigin = .manualAddress // maybeAutoConnect overrides this; the retry bound is everEstablished
        let iface = selectedInterface
        let identity = LocalIdentity.shared
        // Manual IP has no advertised device id, so key pinning can't be pre-enforced here (the
        // peer's key is still verified against the trust store post-handshake by the Session).
        // Remember the last IP dialed by hand so the field is pre-filled next launch — the
        // Thunderbolt link-local address is stable per cable and tedious to retype. Remember the
        // port alongside it so launch auto-connect re-dials the exact rung the Display last bound
        // (it may have laddered off the well-known port).
        UserDefaults.standard.set(host, forKey: SourceController.lastHostKey)
        UserDefaults.standard.set(Int(port), forKey: SourceController.lastPortKey)
        let label = port == ProtocolConstants.fallbackPort ? host : "\(host):\(port)"
        startLink(peerName: host, target: .address(label), expectedPeerId: nil) {
            TCPTransport(host: host, port: port, interface: iface, identity: identity)
        }
    }

    /// Dial a hand-typed address. Unparseable input is refused rather than dialled — see
    /// `Address.parse` (SidewireProtocol) for why that distinction is load-bearing. The UI runs
    /// the same parse to gate its button, so this guard should never be the one that fires.
    func connect(manualAddress raw: String) {
        guard let parsed = Address.parse(raw) else { return }
        connect(host: parsed.host, port: parsed.port)
    }

    /// The device id to enforce (keyChanged) for a discovered peer: its advertised id, but only
    /// if we have already pinned it. nil for an unknown/unpaired peer (first-time pairing).
    private func pinnedExpectation(for advertisedId: String?) -> String? {
        guard let advertisedId, KeychainTrustStore.shared.pinned(for: advertisedId) != nil else { return nil }
        return advertisedId
    }

    /// Whether we've already paired with this peer — i.e. its advertised key is in the trust store,
    /// so connecting needs no PIN. Drives the connect flow: a paired Mac connects in one click; an
    /// unpaired one asks for the 6-digit code first. Updated as the trust store changes, so the UI
    /// must re-read it (it observes `.sidewirePairedPeersChanged`).
    func isPaired(_ peer: DiscoveredPeer) -> Bool {
        pinnedExpectation(for: peer.deviceId) != nil
    }

    static let lastHostKey = "sidewire.lastHost"
    static var lastHost: String { UserDefaults.standard.string(forKey: lastHostKey) ?? "" }
    /// The port that went with `lastHost`, so launch auto-connect re-dials the exact rung the
    /// Display last bound (it may have laddered off the well-known port). Defaults to
    /// `fallbackPort` when unset (a first launch, or an install from before the port was persisted).
    static let lastPortKey = "sidewire.lastPort"
    static var lastPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: lastPortKey) // 0 when unset
        return stored > 0 && stored <= Int(UInt16.max) ? UInt16(stored) : ProtocolConstants.fallbackPort
    }

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
        reconnectingSince = nil
        isConnected = false
        isConnecting = false
        isStreaming = false
        pinRejected = false
        accessibilityRevoked = false
        injector.injectionEnabled = true
        linkTarget = nil
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
        let wasProven = everEstablished
        let target = linkTarget ?? .address(name) // re-dial the same target the D3 session had
        let origin = linkOrigin
        Log.event(.source, "reconnecting to apply new quality settings")
        disconnect() // clears currentMakeTransport / linkTarget — hence the local captures above
        startLink(peerName: name, target: target, expectedPeerId: expected, makeTransport: make)
        // We were streaming from this exact peer a moment ago, so it is proven and must keep the
        // unbounded self-healing retries. Without this, startLink's reset would drop a deliberate
        // re-dial onto the bounded first-connect path and give up on a Mac we know is right there.
        everEstablished = wasProven
        linkOrigin = origin // preserve why the link exists, so a give-up message stays accurate
    }

    // MARK: - Connection

    private func startLink(peerName: String, target: LinkTarget, expectedPeerId: String?,
                           makeTransport: @escaping () -> TCPTransport) {
        guard reconnector == nil else { return } // ignore re-entrant connects
        pinRejected = false // fresh attempt clears any prior wrong-PIN error
        everEstablished = false // a new link is unproven until its handshake completes
        self.peerName = peerName
        self.linkTarget = target
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

    /// What to tell the user when a first connect gives up. Each origin leaves them somewhere
    /// different, and the advice has to match: telling someone who picked a Mac off the discovered
    /// list to "check the address" is nonsense — they never typed one, and that Mac is provably on
    /// the network running Sidewire, because that is how it got into the list.
    private static func giveUpText(origin: LinkOrigin, name: String) -> String {
        switch origin {
        case .autoConnect:
            return String(localized: "Couldn't reach \(name) automatically. Pick it below to try again.")
        case .discovered:
            return String(localized: "\(name) is on the network but isn't answering. Try quitting and reopening Sidewire on that Mac.")
        case .manualAddress:
            return String(localized: "Couldn't reach \(name). Check the address, and that Sidewire is open on that Mac and set to be the screen.")
        }
    }

    private func applyLinkState(_ state: Reconnector.LinkState) {
        guard reconnector != nil else { return } // ignore late callbacks after disconnect()
        switch state {
        case .connecting:
            isConnecting = true; isConnected = false; statusText = String(localized: "Connecting…")
            Log.event(.source, "link: connecting")
        case .streaming:
            isConnecting = false; isConnected = true; statusText = String(localized: "Connected")
            everEstablished = true // from here on, retries are self-healing and stay unbounded
            reconnectingSince = nil // a healthy stream clears the phantom-teardown timer
            Log.event(.source, "link: connected")
        case .reconnecting(let attempt):
            // Bound the FIRST connect only. A link that never got established was never right, so
            // retrying it forever just delays the truth — and the delay is worse than useless,
            // because the "Still trying — is Sidewire running on the other Mac?" hint below sends
            // the user off to inspect a Mac that is very likely fine. Once a link HAS been
            // established, `everEstablished` lifts the bound and reconnects run forever, which is
            // the whole point of the self-healing path.
            if !everEstablished, attempt >= Self.maxFirstConnectAttempts {
                Log.event(.source, "first connect gave up after \(attempt) attempts", level: .notice)
                // Both of these are read BEFORE disconnect(), which clears peerName and could
                // clear anything else it likes. Reading state back out of a teardown is how the
                // give-up message ends up describing a situation that no longer exists.
                let name = peerName ?? String(localized: "the other Mac")
                let origin = linkOrigin
                disconnect()
                statusText = Self.giveUpText(origin: origin, name: name)
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
            // Keep the virtual display for a brief blip so a fast reconnect preserves window
            // layout — but if the peer stays gone (a hard drop with no BYE: crash, cable pull, or
            // a quit whose goodbye didn't flush), remove the phantom desktop so the cursor can't
            // wander onto a screen with no Mac behind it. prepareStreaming() recreates it if the
            // peer returns.
            if reconnectingSince == nil { reconnectingSince = Date() }
            if let since = reconnectingSince, Date().timeIntervalSince(since) >= phantomLingerSeconds,
               virtualDisplay.isActive {
                Log.event(.source, "reconnect exceeded \(Int(phantomLingerSeconds))s — removing the virtual display so the cursor can't stray onto it", level: .notice)
                virtualDisplay.destroy()
            }
        case .failed(let reason):
            // Terminal (protocol/role mismatch, wrong PIN, key changed, rate-limited, or displaced
            // by another Source): tear down and release the reconnector so a fresh connect() can
            // proceed.
            isConnecting = false; isConnected = false
            // pinRejected drives a dedicated field-level hint; the human status copy for every
            // reason (auth/keyChanged/rateLimited/superseded included) lives once in CloseReasonText.
            if reason == SessionConstants.authFailureReason { pinRejected = true }
            // On a wrong PIN or a changed key, drop any stale pin so the next connect runs a fresh
            // CPace pairing instead of skipping it and being refused again. Prefer the expected-peer id
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
            linkTarget = nil // the link is gone — release every row/section that was tied to it
            tearDownEncoderCapture()
            virtualDisplay.destroy()
            activeSession = nil
            pendingConfig = nil
            reconnector = nil
            reconnectingSince = nil
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
            statusText = String(localized: "Creating the extra screen…")
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
        // Out-of-band cursor feed: track the pointer over the virtual display and stream its
        // position so the Display warps its native cursor there. Bound to THIS session (weakly),
        // and restarted from scratch each time streaming (re)begins.
        cursorTracker.virtualDisplayID = displayID
        cursorTracker.onCursor = { [weak session] x, y in session?.sendCursor(x: x, y: y) }
        cursorTracker.start()
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
        cursorTracker.stop() // covers reconnect/failed/disconnect (all route through here)
        capture.setSampleHandler(nil)
        Task { await capture.stopCapture() }
        encoder?.flush()
        encoder?.invalidate()
        encoder = nil
        lastKeyframe = nil
        isStreaming = false
    }
}
