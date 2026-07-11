import Foundation
import SidewireProtocol

/// Coarse session phase. Phase 0 is intentionally minimal; the full reconnect state
/// machine (idle/discovering/…/reconnecting/paused/failed) arrives in Phase 1.
public enum SessionPhase: Sendable, Equatable {
    case connecting
    case handshaking
    case streaming
    case closed(String?)
}

/// Drives one connection through HELLO → HELLO_ACK → DISPLAY_INFO → CONFIG, then
/// relays video/input. Symmetric: the same class runs on both the dialed (Source)
/// and accepted (Display) sides; behavior branches on `role`.
///
/// Runs its logic on a private serial queue. All `on*` callbacks fire on that queue;
/// callers hop to the main thread / media queues as needed.
public final class Session: @unchecked Sendable {
    private let transport: Transport
    private let role: Role
    private let localHello: Hello
    private let queue = DispatchQueue(label: "sidewire.session")

    // Display supplies its native panel info (Source reads the peer's).
    public var provideDisplayInfo: (() -> DisplayInfo?)?

    // Fired once, when the streaming Config is agreed on this side.
    public var onReady: ((Config) -> Void)?
    // Source side: the Display's native panel info arrived.
    public var onDisplayInfo: ((DisplayInfo) -> Void)?
    // Display side: a decoded-ready video frame arrived (nal, isKeyframe, ltrToken).
    public var onVideoFrame: ((Data, Bool, UInt16) -> Void)?
    // Source side: an input event arrived.
    public var onInputEvent: ((InputEventRecord) -> Void)?
    // Display side: source requests a keyframe.
    public var onRequestIDR: (() -> Void)?
    public var onPhaseChange: ((SessionPhase) -> Void)?
    public var onClosed: ((String?) -> Void)?
    /// Fired (~2 Hz) with the round-trip time in ms, measured on a single clock.
    public var onRTT: ((Double) -> Void)?
    /// Fired once the transport is ready, with the network interface in use.
    public var onInterface: ((String) -> Void)?
    /// Source side: the receiver acknowledged these long-term-reference tokens.
    public var onLTRAck: (([UInt16]) -> Void)?

    /// Source override for the virtual-display resolution (nil = match the Display's native).
    /// Set before start().
    public var preferredDimensions: (width: Int, height: Int)?

    private var seq: UInt32 = 0
    private var peerHello: Hello?
    private var peerDisplayInfo: DisplayInfo?
    private var configSent = false
    private var ready = false
    private var closed = false
    private var transportReady = false
    private(set) public var phase: SessionPhase = .connecting

    // Liveness: an application-level heartbeat with a dead-peer watchdog. This is the
    // primary detector (TCP's own default is ~2h and a blocked send can hang forever).
    private var heartbeatTimer: DispatchSourceTimer?
    private var connectTimer: DispatchSourceTimer?
    private var lastInboundNanos: UInt64 = 0
    private(set) public var lastRTTms: Double = 0

    public init(transport: Transport, role: Role, localHello: Hello) {
        self.transport = transport
        self.role = role
        self.localHello = localHello
    }

    public var peerName: String? { peerHello?.deviceName }

    public func start() {
        transport.onState = { [weak self] state in
            self?.queue.async { self?.handleState(state) }
        }
        transport.onFrame = { [weak self] frame in
            self?.queue.async { self?.handle(frame) }
        }
        transport.onInterface = { [weak self] label in
            self?.queue.async { self?.onInterface?(label) }
        }
        setPhase(.connecting)
        armConnectTimeout()
        transport.start()
    }

    /// One-shot bound on reaching streaming. Because transient `.waiting` is non-fatal,
    /// this is what eventually fails a connection to a down/absent peer so the Reconnector
    /// re-dials (re-resolving the Bonjour service).
    private func armConnectTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + SessionConstants.connectTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, !self.ready, !self.closed else { return }
            coreLog.notice("session[\(self.role.rawValue, privacy: .public)] connect/handshake timeout → closing")
            self.finishClose("timeout")
        }
        connectTimer = timer
        timer.resume()
    }

    private func cancelConnectTimeout() {
        connectTimer?.cancel()
        connectTimer = nil
    }

    // MARK: - Sending (public API for controllers)

    public func sendVideo(_ nal: Data, keyframe: Bool, ltrToken: UInt16 = 0) {
        queue.async {
            guard self.ready, !self.closed else { return }
            var flags = VideoFlags()
            if keyframe { flags.insert(.keyframe) }
            if ltrToken != 0 { flags.insert(.ltr) }
            let payload = VideoPayload.encode(ltrToken: ltrToken, nalData: nal)
            self.transport.send(type: .video, flags: flags.rawValue, seq: self.nextSeq(), payload: payload)
        }
    }

    public func sendInput(_ rec: InputEventRecord) {
        queue.async {
            guard self.ready, !self.closed else { return }
            self.transport.send(type: .input, seq: self.nextSeq(), payload: rec.encoded)
        }
    }

    public func requestIDR() {
        queue.async {
            guard !self.closed else { return }
            self.transport.send(type: .requestIDR, seq: self.nextSeq(), payload: Data())
        }
    }

    /// Display side: acknowledge received long-term-reference tokens.
    public func sendLTRAck(_ tokens: [UInt16]) {
        guard !tokens.isEmpty else { return }
        queue.async {
            guard self.ready, !self.closed else { return }
            self.transport.send(type: .ltrAck, seq: self.nextSeq(), payload: LTRAckPayload.encode(tokens))
        }
    }

    public func close(reason: String) {
        queue.async {
            guard !self.closed else { return }
            // Only send BYE if the transport actually reached .ready; sending into a
            // not-yet-ready connection is pointless and races the teardown.
            if self.transportReady {
                self.transport.send(type: .bye, seq: self.nextSeq(),
                                    payload: JSONWire.encode(ReasonMessage(reason: reason)))
            }
            self.finishClose(reason)
        }
    }

    // MARK: - Inbound

    private func handleState(_ state: TransportState) {
        switch state {
        case .ready:
            transportReady = true
            setPhase(.handshaking)
            coreLog.info("session[\(self.role.rawValue, privacy: .public)] transport ready → sending HELLO")
            startHeartbeat()
            sendHello()
            if role == .display, let info = provideDisplayInfo?() {
                coreLog.info("session[display] sending DISPLAY_INFO \(info.width)x\(info.height)")
                transport.send(type: .displayInfo, seq: nextSeq(), payload: JSONWire.encode(info))
            }
        case .failed(let msg):
            finishClose(msg)
        case .cancelled:
            finishClose(nil)
        case .waiting(let msg):
            // Transient — Network.framework keeps retrying (normal during initial connect
            // and brief flaps). Don't close here; the heartbeat watchdog catches a real
            // death in ~2.5s, avoiding a needless reconnect on a momentary blip.
            coreLog.notice("session[\(self.role.rawValue, privacy: .public)] transport waiting: \(msg, privacy: .public)")
        case .setup:
            break
        }
    }

    private func handle(_ frame: Frame) {
        guard !closed else { return }
        lastInboundNanos = DispatchTime.now().uptimeNanoseconds // any inbound frame = peer is alive
        guard let type = frame.type else { return } // unknown/reserved type → skip (forward compatibility)
        switch type {
        case .hello, .helloAck:
            if let hello = JSONWire.decode(Hello.self, from: frame.payload) {
                receiveHello(hello, isAck: frame.type == .helloAck)
            }
        case .displayInfo:
            if role == .source, let info = JSONWire.decode(DisplayInfo.self, from: frame.payload) {
                peerDisplayInfo = info
                onDisplayInfo?(info)
                finalizeIfPossible()
            }
        case .config:
            if role == .display, let cfg = JSONWire.decode(Config.self, from: frame.payload) {
                becomeReady(cfg)
            }
        case .video:
            if role == .display, let (token, nal) = VideoPayload.decode(frame.payload) {
                let isKey = (frame.flags & VideoFlags.keyframe.rawValue) != 0
                onVideoFrame?(nal, isKey, token)
            }
        case .input:
            if role == .source, let rec = InputEventRecord.decode(from: frame.payload) {
                onInputEvent?(rec)
            }
        case .ping:
            transport.send(type: .pong, seq: nextSeq(), payload: frame.payload) // echo
        case .pong:
            if let sent = HeartbeatPayload.decode(frame.payload) {
                let rtt = Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000
                lastRTTms = rtt
                onRTT?(rtt)
            }
        case .requestIDR:
            if role == .source { onRequestIDR?() }
        case .ltrAck:
            if role == .source { onLTRAck?(LTRAckPayload.decode(frame.payload)) }
        case .bye:
            let reason = JSONWire.decode(ReasonMessage.self, from: frame.payload)?.reason
            finishClose(reason)
        default:
            break // audio/ltrAck/feedback/pause/resume — reserved for later phases
        }
    }

    private func receiveHello(_ hello: Hello, isAck: Bool) {
        coreLog.info("session[\(self.role.rawValue, privacy: .public)] recv HELLO from \(hello.deviceName, privacy: .public) role=\(hello.role.rawValue, privacy: .public) ack=\(isAck)")
        if let rejection = hello.validate(againstLocalRole: role) {
            coreLog.error("session[\(self.role.rawValue, privacy: .public)] rejecting peer: \(rejection.rawValue, privacy: .public)")
            transport.send(type: .bye, seq: nextSeq(),
                           payload: JSONWire.encode(ReasonMessage(reason: rejection.rawValue)))
            finishClose(rejection.rawValue)
            return
        }
        if peerHello == nil {
            peerHello = hello
            if !isAck {
                // Reply with our HELLO_ACK so the peer has our capabilities regardless of order.
                transport.send(type: .helloAck, seq: nextSeq(), payload: JSONWire.encode(localHello))
            }
        }
        finalizeIfPossible()
    }

    /// Source-side: once we have the peer HELLO and the Display's info, compute and send CONFIG.
    private func finalizeIfPossible() {
        guard role == .source, !configSent, let peer = peerHello else { return }
        // We need the display info to size the virtual display exactly.
        guard let info = peerDisplayInfo else { return }
        let cfg = Self.negotiate(local: localHello, peer: peer, displayInfo: info, override: preferredDimensions)
        configSent = true
        coreLog.info("session[source] sending CONFIG codec=\(cfg.codec, privacy: .public) \(cfg.width)x\(cfg.height)@\(cfg.fps)")
        transport.send(type: .config, seq: nextSeq(), payload: JSONWire.encode(cfg))
        becomeReady(cfg)
    }

    private func becomeReady(_ cfg: Config) {
        guard !ready else { return }
        ready = true
        cancelConnectTimeout()
        setPhase(.streaming)
        coreLog.info("session[\(self.role.rawValue, privacy: .public)] READY codec=\(cfg.codec, privacy: .public) \(cfg.width)x\(cfg.height)@\(cfg.fps)")
        onReady?(cfg)
    }

    // MARK: - Helpers

    static func negotiate(local: Hello, peer: Hello, displayInfo: DisplayInfo?,
                          override: (width: Int, height: Int)? = nil) -> Config {
        let codec = local.capabilities.videoCodecs.first { peer.capabilities.videoCodecs.contains($0) } ?? "h264"
        let width = override?.width ?? displayInfo?.width ?? min(local.capabilities.maxWidth, peer.capabilities.maxWidth)
        let height = override?.height ?? displayInfo?.height ?? min(local.capabilities.maxHeight, peer.capabilities.maxHeight)
        let fps = min(local.capabilities.maxFps, peer.capabilities.maxFps)
        let ltr = local.capabilities.ltr && peer.capabilities.ltr
        return Config(codec: codec, width: width, height: height, fps: fps, ltr: ltr,
                      bitrateStartBps: 30_000_000, bitrateMinBps: 5_000_000, bitrateMaxBps: 50_000_000)
    }

    private func sendHello() {
        transport.send(type: .hello, seq: nextSeq(), payload: JSONWire.encode(localHello))
    }

    // MARK: - Heartbeat / dead-peer watchdog

    private func startHeartbeat() {
        stopHeartbeat() // idempotent: never orphan a running timer if .ready re-fires
        lastInboundNanos = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + SessionConstants.heartbeatInterval,
                       repeating: SessionConstants.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func heartbeatTick() {
        guard !closed else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let idleMs = Double(now &- lastInboundNanos) / 1_000_000
        if idleMs > SessionConstants.heartbeatTimeout * 1000 {
            coreLog.notice("session[\(self.role.rawValue, privacy: .public)] heartbeat timeout (\(Int(idleMs))ms silent) → declaring peer dead")
            finishClose("timeout")
            return
        }
        transport.send(type: .ping, seq: nextSeq(), payload: HeartbeatPayload.encode(now))
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func nextSeq() -> UInt32 {
        let s = seq
        seq &+= 1
        return s
    }

    private func setPhase(_ p: SessionPhase) {
        phase = p
        onPhaseChange?(p)
    }

    private func finishClose(_ reason: String?) {
        guard !closed else { return }
        closed = true
        stopHeartbeat()
        cancelConnectTimeout()
        coreLog.notice("session[\(self.role.rawValue, privacy: .public)] CLOSED reason=\(reason ?? "nil", privacy: .public)")
        transport.cancel()
        setPhase(.closed(reason))
        onClosed?(reason)
    }
}
