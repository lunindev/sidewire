import Foundation
import Crypto
import SidewireProtocol

/// Coarse session phase. Phase 0 is intentionally minimal; the full reconnect state
/// machine (idle/discovering/…/reconnecting/paused/failed) arrives in Phase 1.
public enum SessionPhase: Sendable, Equatable {
    case connecting
    case handshaking
    case streaming
    case closed(String?)
}

/// Everything the Session needs to run (or skip) the channel-bound PIN proof before HELLO on a
/// cert-based TLS connection (docs/05). Set on the Session before `start()`. When nil (e.g. the
/// in-memory `FakeTransport` used by unit tests, which has no TLS security context), the Session
/// treats the link as already-trusted and goes straight to the application handshake.
public struct PairingConfig: Sendable {
    /// The 6-digit PIN: on the Source it is the code the user typed; on the Display it is the
    /// code this Mac is currently showing.
    public let pin: String
    /// This device's trust store (to check for an existing pin and to pin on success).
    public let trustStore: any TrustStoring
    /// Display side only: rate-limits online PIN guessing. nil on the Source.
    public let rateLimiter: PairingRateLimiter?

    public init(pin: String, trustStore: any TrustStoring, rateLimiter: PairingRateLimiter? = nil) {
        self.pin = pin
        self.trustStore = trustStore
        self.rateLimiter = rateLimiter
    }
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
    // Display side: a video frame arrived (nal, isKeyframe, ltrToken, ptsNanos).
    // ptsNanos is the source's capture timestamp (nanoseconds, monotonic epoch; 0 = unspecified).
    public var onVideoFrame: ((Data, Bool, UInt16, UInt64) -> Void)?
    // Source side: an input event arrived.
    public var onInputEvent: ((InputEventRecord) -> Void)?
    // Display side: source requests a keyframe.
    public var onRequestIDR: (() -> Void)?
    public var onPhaseChange: ((SessionPhase) -> Void)?
    public var onClosed: ((String?) -> Void)?
    /// Fired (on the session queue) when a peer is newly pinned via a successful PIN proof, so
    /// the UI can refresh its "Paired Macs" list. Not fired on a paired reconnect (no new pin).
    public var onPaired: ((TrustedPeer) -> Void)?
    /// Fired (~2 Hz) with the round-trip time in ms, measured on a single clock.
    public var onRTT: ((Double) -> Void)?
    /// Fired once the transport is ready, with the network interface in use.
    public var onInterface: ((String) -> Void)?
    /// Source side: the receiver acknowledged these long-term-reference tokens.
    public var onLTRAck: (([UInt16]) -> Void)?

    /// Source override for the virtual-display resolution (nil = match the Display's native).
    /// Set before start().
    public var preferredDimensions: (width: Int, height: Int)?
    /// Source stream-preference overrides (nil / 0 = negotiate normally). Set before start().
    public var preferredCodec: String?
    public var preferredMaxFps: Int?
    public var preferredMaxBitrateBps: Int?
    /// Source override for virtual-display scale: nil = auto (derive from the Display's
    /// scaleFactor), true = force HiDPI (2×), false = force standard (1×). Set before start().
    public var preferredHiDPI: Bool?

    /// Pairing configuration (PIN + trust store + optional rate limiter). nil ⇒ no PIN proof
    /// (fake-transport unit tests, or a link with no TLS security context). Set before start().
    public var pairingConfig: PairingConfig?

    // Pairing (channel-bound PIN proof) state.
    private var tlsPeerInfo: TLSPeerInfo?
    private var pairingKey: SymmetricKey?
    /// Set once the application handshake (HELLO exchange) has begun, i.e. pairing is done or
    /// was not required. Until then only pairing/BYE messages are processed.
    private var appHandshakeStarted = false
    /// Source: we sent our proof and are waiting for the Display's proof.
    private var awaitingServerProof = false
    /// Display: we verified the Source's proof and replied with ours (waiting for pairAck).
    private var pairingReplied = false

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
        transport.onSecurity = { [weak self] info in
            self?.queue.async { self?.tlsPeerInfo = info }
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

    /// Send one encoded video frame. `ptsNanos` is the capture presentation timestamp in
    /// nanoseconds on the source's monotonic clock (0 = unspecified, e.g. a keep-alive resend);
    /// it rides the video subheader so a receiver can build a jitter buffer / HUD later. `ltrToken`
    /// is reserved for future loss recovery — senders currently always pass 0.
    public func sendVideo(_ nal: Data, keyframe: Bool, ltrToken: UInt16 = 0, ptsNanos: UInt64 = 0) {
        queue.async {
            guard self.ready, !self.closed else { return }
            var flags = VideoFlags()
            if keyframe { flags.insert(.keyframe) }
            if ltrToken != 0 { flags.insert(.ltr) }
            let payload = VideoPayload.encode(ltrToken: ltrToken, ptsNanos: ptsNanos, nalData: nal)
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
                self.sendBye(reason)
                self.finishClose(reason, flushBye: true)
            } else {
                self.finishClose(reason)
            }
        }
    }

    // MARK: - Inbound

    private func handleState(_ state: TransportState) {
        switch state {
        case .ready:
            transportReady = true
            setPhase(.handshaking)
            beginPairingOrHandshake()
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

    // MARK: - Pairing (channel-bound PIN proof, pre-HELLO)

    /// Decide, once TLS is ready, whether to run the PIN proof or go straight to the application
    /// handshake. See docs/05 and PairingProof for the byte-exact scheme.
    private func beginPairingOrHandshake() {
        // No pairing config (unit tests) or no TLS security context ⇒ trust the link as-is.
        guard let pairing = pairingConfig, let tls = tlsPeerInfo else {
            beginApplicationHandshake()
            return
        }
        // Already paired with exactly this key? Skip the proof (paired reconnect).
        if let pinned = pairing.trustStore.pinned(for: tls.peerDeviceId),
           pinned.spkiHash == tls.peerSPKIHash.hexString {
            coreLog.info("session[\(self.role.rawValue, privacy: .public)] peer \(tls.peerDeviceId, privacy: .public) already paired → skipping proof")
            beginApplicationHandshake()
            return
        }
        // Unpaired → derive the pairing key. The Source proves first; the Display waits for the
        // Source's proof (its own decision to skip is impossible here — it has no pin — so it can
        // only pair). See handlePairProof.
        pairingKey = PairingProof.deriveKey(pin: pairing.pin, channelBinding: tls.channelBinding)
        if role == .source {
            let proof = PairingProof.proof(key: pairingKey!, label: PairingProof.clientLabel)
            coreLog.info("session[source] sending PIN proof (pairing \(tls.peerDeviceId, privacy: .public))")
            awaitingServerProof = true
            transport.send(type: .pairProof, seq: nextSeq(), payload: proof)
        } else {
            // Display waits for the Source's proof; rate-limit checked when it arrives.
            coreLog.info("session[display] awaiting PIN proof (pairing \(tls.peerDeviceId, privacy: .public))")
        }
    }

    private func handlePairProof(_ payload: Data) {
        guard let pairing = pairingConfig, let tls = tlsPeerInfo, let key = pairingKey else { return }
        if role == .display {
            guard !pairingReplied else { return } // one proof per attempt
            // Rate-limit online guessing before doing any work.
            if let limiter = pairing.rateLimiter, !limiter.allowAttempt() {
                coreLog.notice("session[display] pairing locked out → BYE(rateLimited)")
                closeSendingBye(SessionConstants.rateLimitedReason)
                return
            }
            if PairingProof.verify(payload, key: key, label: PairingProof.clientLabel) {
                pairing.rateLimiter?.recordSuccess()
                pinPeer(tls, trustStore: pairing.trustStore)
                pairingReplied = true
                let serverProof = PairingProof.proof(key: key, label: PairingProof.serverLabel)
                coreLog.info("session[display] Source PIN proof OK → replying, awaiting ack")
                transport.send(type: .pairProof, seq: nextSeq(), payload: serverProof)
            } else {
                pairing.rateLimiter?.recordFailure()
                coreLog.notice("session[display] Source PIN proof MISMATCH → BYE(auth)")
                closeSendingBye(SessionConstants.authFailureReason)
            }
        } else { // .source: this is the Display's proof
            guard awaitingServerProof else { return }
            awaitingServerProof = false
            if PairingProof.verify(payload, key: key, label: PairingProof.serverLabel) {
                pinPeer(tls, trustStore: pairing.trustStore)
                coreLog.info("session[source] Display PIN proof OK → ack + handshake")
                transport.send(type: .pairAck, seq: nextSeq(), payload: Data())
                beginApplicationHandshake()
            } else {
                coreLog.notice("session[source] Display PIN proof MISMATCH → BYE(auth)")
                closeSendingBye(SessionConstants.authFailureReason)
            }
        }
    }

    private func handlePairAck() {
        guard role == .display, pairingReplied, !appHandshakeStarted else { return }
        coreLog.info("session[display] pairing ack received → handshake")
        beginApplicationHandshake()
    }

    /// The Display received a HELLO before pairing completed: the Source skipped the proof, so it
    /// considers itself paired. Accept only if we have it pinned too; otherwise refuse (one side
    /// forgot the pin → the Source must re-pair). The Source never reaches here (the Display does
    /// not send HELLO until pairing completes).
    private func handlePreHandshakeHello(_ frame: Frame) {
        guard role == .display, let pairing = pairingConfig, let tls = tlsPeerInfo else { return }
        if pairing.trustStore.pinned(for: tls.peerDeviceId) != nil {
            beginApplicationHandshake()
            handle(frame) // now process the HELLO through the normal path
        } else {
            coreLog.notice("session[display] unpinned Source skipped pairing → BYE(auth)")
            closeSendingBye(SessionConstants.authFailureReason)
        }
    }

    private func pinPeer(_ tls: TLSPeerInfo, trustStore: any TrustStoring) {
        let peer = TrustedPeer(deviceId: tls.peerDeviceId, spkiHash: tls.peerSPKIHash.hexString,
                               name: peerHello?.deviceName ?? "")
        trustStore.pin(peer)
        coreLog.info("session[\(self.role.rawValue, privacy: .public)] pinned peer \(tls.peerDeviceId, privacy: .public)")
        onPaired?(peer)
    }

    /// Begin the application handshake (HELLO exchange). Called directly when no pairing is
    /// required, or after a successful PIN proof / on a paired reconnect.
    private func beginApplicationHandshake() {
        guard !appHandshakeStarted else { return }
        appHandshakeStarted = true
        coreLog.info("session[\(self.role.rawValue, privacy: .public)] transport ready → sending HELLO")
        startHeartbeat()
        sendHello()
        // DISPLAY_INFO is deferred until AFTER the peer's HELLO is received and validated (E6):
        // sending it here would leak the panel description to a peer we then reject. See
        // receiveHello, which emits it right after the Display's HELLO_ACK.
    }

    private func sendBye(_ reason: String) {
        transport.send(type: .bye, seq: nextSeq(), payload: JSONWire.encode(ReasonMessage(reason: reason)))
    }

    /// Send a BYE(reason) and close, letting the BYE flush so the peer sees the reason.
    private func closeSendingBye(_ reason: String) {
        sendBye(reason)
        finishClose(reason, flushBye: true)
    }

    private func handle(_ frame: Frame) {
        guard !closed else { return }
        lastInboundNanos = DispatchTime.now().uptimeNanoseconds // any inbound frame = peer is alive
        guard let type = frame.type else { return } // unknown/reserved type → skip (forward compatibility)

        // Pre-handshake pairing gate: until the application handshake has begun on a pairing
        // link, only pairing messages (and BYE) are processed.
        if pairingConfig != nil, !appHandshakeStarted {
            switch type {
            case .pairProof: handlePairProof(frame.payload)
            case .pairAck: handlePairAck()
            case .hello, .helloAck: handlePreHandshakeHello(frame)
            case .bye: finishClose(JSONWire.decode(ReasonMessage.self, from: frame.payload)?.reason)
            default: break // ignore video/input/etc. until pairing completes
            }
            return
        }

        switch type {
        case .hello, .helloAck:
            // Fail loud on a malformed handshake message (was: silent drop → 10s timeout). A
            // foreign/garbled peer gets a clear BYE("protocol") instead of a hang.
            guard let hello = JSONWire.decode(Hello.self, from: frame.payload) else {
                coreLog.error("session[\(self.role.rawValue, privacy: .public)] malformed HELLO → BYE(protocol)")
                closeSendingBye(HelloRejection.protocolMismatch.rawValue)
                return
            }
            receiveHello(hello, isAck: frame.type == .helloAck)
        case .displayInfo:
            if role == .source {
                guard let info = JSONWire.decode(DisplayInfo.self, from: frame.payload) else {
                    coreLog.error("session[source] malformed DISPLAY_INFO → BYE(protocol)")
                    closeSendingBye(HelloRejection.protocolMismatch.rawValue)
                    return
                }
                peerDisplayInfo = info
                onDisplayInfo?(info)
                finalizeIfPossible()
            }
        case .config:
            if role == .display {
                guard let cfg = JSONWire.decode(Config.self, from: frame.payload) else {
                    coreLog.error("session[display] malformed CONFIG → BYE(protocol)")
                    closeSendingBye(HelloRejection.protocolMismatch.rawValue)
                    return
                }
                becomeReady(cfg)
            }
        case .video:
            if role == .display, let (token, pts, nal) = VideoPayload.decode(frame.payload) {
                let isKey = (frame.flags & VideoFlags.keyframe.rawValue) != 0
                onVideoFrame?(nal, isKey, token, pts)
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
            break // audio/pause/resume — reserved for later phases; 0x42 (was FEEDBACK) removed
        }
    }

    private func receiveHello(_ hello: Hello, isAck: Bool) {
        coreLog.info("session[\(self.role.rawValue, privacy: .public)] recv HELLO from \(hello.deviceName, privacy: .public) role=\(hello.role.rawValue, privacy: .public) ack=\(isAck)")
        if let rejection = hello.validate(againstLocalRole: role) {
            coreLog.error("session[\(self.role.rawValue, privacy: .public)] rejecting peer: \(rejection.rawValue, privacy: .public)")
            closeSendingBye(rejection.rawValue)
            return
        }
        // Future-proofing: the peers must agree on the wire input encoding. Both v2 implementations
        // send "hid1"; a peer advertising something else is refused rather than fed misinterpreted
        // keycodes. (Optional-with-default on decode, so an absent field reads as "hid1".)
        if hello.capabilities.inputMapping != localHello.capabilities.inputMapping {
            coreLog.error("session[\(self.role.rawValue, privacy: .public)] input mapping mismatch (peer=\(hello.capabilities.inputMapping, privacy: .public), local=\(self.localHello.capabilities.inputMapping, privacy: .public)) → BYE(protocol)")
            closeSendingBye(HelloRejection.protocolMismatch.rawValue)
            return
        }
        if peerHello == nil {
            peerHello = hello
            // The peer was pinned during the proof before its HELLO (name unknown then); now that
            // we have its human name, fill it in on the trust-store entry.
            if let pairing = pairingConfig, let tls = tlsPeerInfo,
               let pinned = pairing.trustStore.pinned(for: tls.peerDeviceId), pinned.name != hello.deviceName {
                pairing.trustStore.pin(TrustedPeer(deviceId: pinned.deviceId, spkiHash: pinned.spkiHash,
                                                   name: hello.deviceName, pairedAt: pinned.pairedAt))
            }
            if !isAck {
                // Reply with our HELLO_ACK so the peer has our capabilities regardless of order.
                transport.send(type: .helloAck, seq: nextSeq(), payload: JSONWire.encode(localHello))
            }
            // E6: the Display sends DISPLAY_INFO only now — after the Source's HELLO is received and
            // validated (right after our HELLO_ACK) — so a rejected peer never learns our panel.
            if role == .display, let info = provideDisplayInfo?() {
                coreLog.info("session[display] sending DISPLAY_INFO \(info.width)x\(info.height)")
                transport.send(type: .displayInfo, seq: nextSeq(), payload: JSONWire.encode(info))
            }
        }
        finalizeIfPossible()
    }

    /// Source-side: once we have the peer HELLO and the Display's info, compute and send CONFIG.
    private func finalizeIfPossible() {
        guard role == .source, !configSent, let peer = peerHello else { return }
        // We need the display info to size the virtual display exactly.
        guard let info = peerDisplayInfo else { return }
        // No shared video codec ⇒ fail the handshake loudly (BYE "protocol") rather than
        // silently streaming a codec the peer can't decode. Mirrors Hello.validate rejections.
        guard let cfg = Self.negotiate(local: localHello, peer: peer, displayInfo: info,
                                       override: preferredDimensions, codecOverride: preferredCodec,
                                       fpsCap: preferredMaxFps, maxBitrateBps: preferredMaxBitrateBps,
                                       hiDPIOverride: preferredHiDPI) else {
            let reason = HelloRejection.protocolMismatch.rawValue
            coreLog.error("session[source] no common video codec with peer → BYE(\(reason, privacy: .public))")
            closeSendingBye(reason)
            return
        }
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

    /// Returns nil when the peers share no video codec, so the caller fails the handshake
    /// (BYE "protocol") instead of streaming an undecodable codec.
    static func negotiate(local: Hello, peer: Hello, displayInfo: DisplayInfo?,
                          override: (width: Int, height: Int)? = nil,
                          codecOverride: String? = nil,
                          fpsCap: Int? = nil,
                          maxBitrateBps: Int? = nil,
                          hiDPIOverride: Bool? = nil) -> Config? {
        guard let common = local.capabilities.videoCodecs.first(where: {
            peer.capabilities.videoCodecs.contains($0)
        }) else { return nil }
        // Honor a codec override only if BOTH peers actually support it.
        let codec: String
        if let c = codecOverride,
           local.capabilities.videoCodecs.contains(c), peer.capabilities.videoCodecs.contains(c) {
            codec = c
        } else {
            codec = common
        }
        let width = override?.width ?? displayInfo?.width ?? min(local.capabilities.maxWidth, peer.capabilities.maxWidth)
        let height = override?.height ?? displayInfo?.height ?? min(local.capabilities.maxHeight, peer.capabilities.maxHeight)
        var fps = min(local.capabilities.maxFps, peer.capabilities.maxFps)
        if let cap = fpsCap, cap > 0 { fps = min(fps, cap) }
        let ltr = local.capabilities.ltr && peer.capabilities.ltr
        // Match the Display's scale unless overridden: scaleFactor >= 2 ⇒ HiDPI, == 1 ⇒ 1×.
        let hiDPI = hiDPIOverride ?? ((displayInfo?.scaleFactor ?? 2.0) >= 2.0)
        let maxBps = maxBitrateBps ?? 50_000_000
        let startBps = min(30_000_000, maxBps)
        let minBps = min(5_000_000, maxBps)
        return Config(codec: codec, width: width, height: height, fps: fps, ltr: ltr,
                      bitrateStartBps: startBps, bitrateMinBps: minBps, bitrateMaxBps: maxBps,
                      hiDPI: hiDPI)
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

    /// Tear down the session. When `flushBye` is true (a BYE was just sent), the transport cancel
    /// is deferred briefly so the BYE flushes over TLS and the peer receives the reason instead of
    /// a bare connection reset — this is what makes a wrong-PIN "auth" (etc.) reach the other Mac.
    private func finishClose(_ reason: String?, flushBye: Bool = false) {
        guard !closed else { return }
        closed = true
        stopHeartbeat()
        cancelConnectTimeout()
        coreLog.notice("session[\(self.role.rawValue, privacy: .public)] CLOSED reason=\(reason ?? "nil", privacy: .public)")
        if flushBye {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.transport.cancel() }
        } else {
            transport.cancel()
        }
        setPhase(.closed(reason))
        onClosed?(reason)
    }
}
