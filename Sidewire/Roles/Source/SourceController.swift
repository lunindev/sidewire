import Foundation
import CoreMedia
import SidewireProtocol
import SidewireCore

/// Source role: discovers Displays, connects (via the self-healing Reconnector), and
/// drives virtual-display → capture → encode → session, plus injects incoming input.
/// @MainActor for SwiftUI observation. Session callbacks self-hop to main.
@MainActor
final class SourceController: ObservableObject {
    let discovery = Discovery()
    let capture = ScreenCapture()
    let virtualDisplay = VirtualDisplayController()

    private let injector = InputInjector()
    private var encoder: VideoEncoder?
    private var reconnector: Reconnector?
    private weak var activeSession: Session?
    private var pendingConfig: Config?
    private var firstEncodedLogged = false

    @Published var peers: [DiscoveredPeer] = []
    @Published var statusText = "Idle"
    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var isConnecting = false
    @Published var peerName: String?
    @Published var rttMs: Double = 0

    init() {
        discovery.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.peers = peers }
        }
        virtualDisplay.onActivated = { [weak self] did in
            Task { @MainActor in self?.beginStreaming(displayID: did) }
        }
    }

    func startDiscovery() { discovery.start() }
    func stopDiscovery() { discovery.stop() }

    func connect(to peer: DiscoveredPeer) {
        startLink(peerName: peer.name) { TCPTransport(endpoint: peer.endpoint) }
    }

    func connect(host: String, port: UInt16 = ProtocolConstants.fallbackPort) {
        startLink(peerName: host) { TCPTransport(host: host, port: port) }
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
                Task { @MainActor in self?.encoder?.forceKeyframe() }
            }
            session.onRTT = { [weak self] rtt in
                Task { @MainActor in self?.rttMs = rtt }
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
        tearDownEncoderCapture() // clear any wiring bound to a previous session
        injector.virtualDisplayID = displayID
        firstEncodedLogged = false
        Log.media.info("virtual display \(displayID) active → starting capture \(config.width)x\(config.height)@\(config.fps) codec=\(config.codec)")

        let enc = VideoEncoder(width: Int32(config.width), height: Int32(config.height),
                               codec: VideoCodec(rawValue: config.codec) ?? .hevc,
                               fps: config.fps, bitrate: config.bitrateStartBps)
        encoder = enc
        enc.forceKeyframe()
        enc.onEncodedFrame = { [weak self, weak session] data, isKey in
            if let self, !self.firstEncodedLogged {
                self.firstEncodedLogged = true
                Log.media.info("first frame ENCODED (\(data.count) bytes, key=\(isKey)) → sending")
            }
            session?.sendVideo(data, keyframe: isKey)
        }
        capture.onSampleBuffer = { [weak enc] sampleBuffer in
            guard let pb = sampleBuffer.imageBuffer else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            enc?.encode(pixelBuffer: pb, presentationTime: pts)
        }

        statusText = "Streaming"
        Task { [weak self] in
            await self?.capture.startCapture(displayID: displayID, fps: config.fps,
                                             pixelWidth: config.width, pixelHeight: config.height)
            await MainActor.run {
                // Ignore a stale completion after teardown (tearDownEncoderCapture nils encoder).
                guard let self, self.encoder === enc else { return }
                self.isStreaming = true
            }
        }
    }

    private func tearDownEncoderCapture() {
        capture.onSampleBuffer = nil
        Task { await capture.stopCapture() }
        encoder?.flush()
        encoder?.invalidate()
        encoder = nil
        isStreaming = false
    }
}
