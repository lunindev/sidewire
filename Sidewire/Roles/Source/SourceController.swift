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
    private var pendingConfig: Config?
    private var firstEncodedLogged = false

    // Source-side monitor: static-screen keep-alive + encoder-stall watchdog.
    private var monitorTimer: Timer?
    private var encodedSinceCheck = 0
    private var ticksSinceEncoded = 0
    private var lastKeyframe: Data?
    private var encoderStallStrikes = 0

    // Adaptive bitrate (RTT-driven congestion control).
    private var currentBitrate = 30_000_000
    private var rttBaseline: Double = 0
    private var rampClearTicks = 0
    private let minBitrate = 5_000_000
    private let maxBitrate = 50_000_000
    @Published var currentBitrateMbps: Double = 0

    @Published var needsScreenRecording = false
    @Published var localThunderboltIP: String?
    @Published var peers: [DiscoveredPeer] = []
    @Published var statusText = "Idle"
    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var isConnecting = false
    @Published var peerName: String?
    @Published var rttMs: Double = 0
    @Published var connectionInterface = ""

    private var wakeObserver: Any?

    init() {
        discovery.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.peers = peers }
        }
        virtualDisplay.onActivated = { [weak self] did in
            Task { @MainActor in self?.beginStreaming(displayID: did) }
        }
        // A capture death (SCStream error) is not a static screen — force a reconnect.
        capture.onStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isStreaming else { return }
                Log.media.notice("capture stopped (\(error.localizedDescription)) → reconnect")
                self.activeSession?.close(reason: "capture-stall")
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
                self.activeSession?.close(reason: "wake")
            }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func startDiscovery() {
        interfaceMonitor.start()
        localThunderboltIP = InterfaceMonitor.localThunderboltIP()
        discovery.start()
    }
    func stopDiscovery() { discovery.stop() }

    /// Re-scan the network for Displays.
    func refreshDiscovery() {
        peers = []
        localThunderboltIP = InterfaceMonitor.localThunderboltIP()
        discovery.stop()
        discovery.start()
    }

    func connect(to peer: DiscoveredPeer) {
        let iface = selectedInterface
        startLink(peerName: peer.name) { TCPTransport(endpoint: peer.endpoint, interface: iface) }
    }

    func connect(host: String, port: UInt16 = ProtocolConstants.fallbackPort) {
        let iface = selectedInterface
        startLink(peerName: host) { TCPTransport(host: host, port: port, interface: iface) }
    }

    func disconnect() {
        reconnector?.stop()
        reconnector = nil
        activeSession = nil
        tearDownEncoderCapture()
        virtualDisplay.destroy()
        pendingConfig = nil
        isConnected = false
        isConnecting = false
        isStreaming = false
        statusText = "Disconnected"
        peerName = nil
        rttMs = 0
        connectionInterface = ""
    }

    // MARK: - Connection

    private func startLink(peerName: String, makeTransport: @escaping () -> TCPTransport) {
        guard reconnector == nil else { return } // ignore re-entrant connects
        self.peerName = peerName

        // One stable HELLO (and sessionId) reused across reconnect attempts — idempotent
        // resume. Built here on the main actor (capabilities read NSScreen).
        let hello = DeviceIdentity.makeHello(role: .source, sessionId: UUID().uuidString)

        let reconnector = Reconnector(makeSession: {
            Session(transport: makeTransport(), role: .source, localHello: hello)
        })
        self.reconnector = reconnector

        reconnector.onSession = { [weak self] session in
            // Called on the reconnector queue: wire media callbacks (they self-hop to main).
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
            Task { @MainActor in self?.applyLinkState(state) }
        }
        reconnector.start()
    }

    private func applyLinkState(_ state: Reconnector.LinkState) {
        guard reconnector != nil else { return } // ignore late callbacks after disconnect()
        switch state {
        case .connecting:
            isConnecting = true; isConnected = false; statusText = "Connecting…"
        case .streaming:
            isConnecting = false; isConnected = true; statusText = "Connected"
        case .reconnecting(let attempt):
            // The session died; drop the encoder/capture but KEEP the virtual display so
            // window layout survives and reconnection is fast.
            isConnected = false; isConnecting = true; isStreaming = false
            statusText = "Reconnecting (\(attempt))…"
            tearDownEncoderCapture()
        case .failed(let reason):
            // Terminal (protocol/role mismatch): tear down and release the reconnector so
            // a fresh connect() can proceed.
            isConnecting = false; isConnected = false
            statusText = "Failed: \(reason)"
            tearDownEncoderCapture()
            virtualDisplay.destroy()
            activeSession = nil
            pendingConfig = nil
            reconnector = nil
        case .stopped:
            isConnecting = false; isConnected = false; statusText = "Disconnected"
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
        // Keep the virtual display alive if it already matches the negotiated size.
        if virtualDisplay.isActive,
           virtualDisplay.width == UInt(config.width),
           virtualDisplay.height == UInt(config.height),
           let did = virtualDisplay.virtualDisplayID {
            beginStreaming(displayID: did)
        } else {
            statusText = "Creating display…"
            virtualDisplay.recreate(width: UInt(config.width), height: UInt(config.height))
        }
    }

    private func beginStreaming(displayID: CGDirectDisplayID) {
        guard reconnector != nil, let config = pendingConfig, let session = activeSession else { return }

        // Gate on Screen Recording: without it ScreenCaptureKit produces no frames, the
        // receiver tears down, and we'd loop forever re-triggering the TCC prompt. Stop
        // the loop and tell the user instead.
        guard CGPreflightScreenCaptureAccess() else {
            Log.media.error("Screen Recording NOT granted for this build → cannot capture; stopping (grant it + relaunch)")
            needsScreenRecording = true
            _ = CGRequestScreenCaptureAccess() // register the app / prompt once
            disconnect()
            statusText = "Grant Screen Recording, then reconnect"
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
        Log.media.info("virtual display \(displayID) active → starting capture \(config.width)x\(config.height)@\(config.fps) codec=\(config.codec)")

        let enc = makeEncoder(config: config, session: session)
        statusText = "Streaming"
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
        enc.onEncodedFrame = { [weak self, weak session] data, isKey, ltrToken in
            Task { @MainActor in
                guard let self else { return }
                self.encodedSinceCheck += 1
                if isKey { self.lastKeyframe = data }
                if !self.firstEncodedLogged {
                    self.firstEncodedLogged = true
                    Log.media.info("first frame ENCODED (\(data.count) bytes, key=\(isKey)) → sending")
                }
            }
            session?.sendVideo(data, keyframe: isKey, ltrToken: ltrToken)
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
        guard isStreaming, let config = pendingConfig, let session = activeSession else { return }
        adaptBitrate()
        let encoded = encodedSinceCheck
        encodedSinceCheck = 0
        if encoded > 0 { encoderStallStrikes = 0; ticksSinceEncoded = 0; return }
        ticksSinceEncoded += 1

        if capture.fps > 2 {
            // Capture is delivering but the encoder produced nothing → stall (wait ~1s).
            guard ticksSinceEncoded >= 2 else { return }
            ticksSinceEncoded = 0
            encoderStallStrikes += 1
            Log.media.notice("encoder stall (\(self.encoderStallStrikes)) — capture fps=\(self.capture.fps) but 0 encoded")
            if encoderStallStrikes >= SessionConstants.encoderStallEscalate {
                encoderStallStrikes = 0
                session.close(reason: "encoder-stall") // escalate → reconnect rebuilds everything
            } else {
                encoder?.invalidate()
                makeEncoder(config: config, session: session)
            }
        } else if let keyframe = lastKeyframe {
            // Static screen: resend the last keyframe so the receiver keeps presenting.
            session.sendVideo(keyframe, keyframe: true)
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
