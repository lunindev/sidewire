import Foundation

/// Session / timing constants. Defined once here (see docs/03-reliability.md § Constants).
/// Many are consumed by the Phase 1 reliability engine; they are defined now so there is
/// a single source of truth and Phase 0 code can already reference the ones it needs.
public enum SessionConstants {
    // Heartbeat (Phase 1)
    public static let heartbeatInterval: TimeInterval = 0.5
    public static let heartbeatTimeout: TimeInterval = 2.5
    public static let heartbeatMissLimit = 5
    // Bound on reaching .streaming after start(). Since transient .waiting is non-fatal,
    // this ensures a Source dialing a down peer eventually fails → the Reconnector re-dials.
    public static let connectTimeout: TimeInterval = 10.0

    // Close reason emitted when the channel-bound PIN proof fails (wrong PIN). Fatal-for-
    // reconnect so the user sees a clear error instead of an endless reconnect loop. Distinct
    // from a plain network refusal ("timeout"/"error"). (In protocol v1 this came from a failed
    // TLS-PSK handshake; in v2 it is a BYE("auth") from the pairing proof — same UX contract.)
    public static let authFailureReason = "auth"

    // Close reason emitted when a paired peer presents a different public key than the pinned
    // one (possible MITM or a reinstalled peer). Fatal-for-reconnect: the user must explicitly
    // re-pair. Detected at the TLS layer on the dialing side (TCPTransport.publishSecurityContext).
    public static let keyChangedReason = "keyChanged"

    // Close reason the Display emits when too many wrong PIN proofs have been attempted and a
    // lockout is in effect (PairingRateLimiter). Fatal-for-reconnect: the Source must wait.
    public static let rateLimitedReason = "rateLimited"

    // Close reason the Display emits when a newer Source connects and displaces the current
    // one ("newest wins"). Fatal-for-reconnect: the ousted Source must NOT auto-redial, or
    // two Sources would steal the Display from each other forever.
    public static let supersededReason = "superseded"

    // MARK: - Reconnect reason registry (docs/02 § BYE)
    //
    // v2 flips the default: an UNKNOWN close reason is FATAL (the Reconnector does not re-dial),
    // so a foreign/newer peer sending a reason we don't understand fails loud instead of looping.
    // Reconnection is gated by an explicit allowlist of *transient* reasons below. Everything not
    // in that set — including all the fatal handshake/security reasons above ("user", "protocol",
    // "role", "error", "auth", "keyChanged", "rateLimited", "superseded") and any unknown token —
    // is fatal-for-reconnect. See `Reconnector.transientReasons`.

    /// Connect/handshake bound or heartbeat-silence timeout. The peer may simply be slow or
    /// briefly away; re-dialing (re-resolving Bonjour) is the correct recovery.
    public static let timeoutReason = "timeout"
    /// Canonical low-level transport failure (TCP reset/refused/abort, interface drop, framing
    /// error). `TCPTransport` maps every non-`keyChanged` `.failed` to this so a network blip
    /// stays transient under the "unknown ⇒ fatal" rule instead of leaking an OS error string.
    public static let transportFailureReason = "transport"
    /// Local sleep/wake: the Source tears down and rebuilds the virtual display + capture on wake.
    public static let wakeReason = "wake"
    /// Source ScreenCaptureKit stream died — rebuild by reconnecting.
    public static let captureStallReason = "capture-stall"
    /// Source encoder wedged (capture delivering, no output) — escalated rebuild by reconnecting.
    public static let encoderStallReason = "encoder-stall"
    /// Display never received a first decoded frame within the grace budget — rebuild.
    public static let noVideoReason = "no-video"
    /// Display video pipeline wedged after streaming started — rebuild.
    public static let noFrameReason = "no-frame"

    /// The complete set of transient (reconnect-eligible) close reasons. Any reason NOT in this
    /// set is fatal-for-reconnect. A `nil` reason is treated as transient (a clean drop). Kept in
    /// lockstep with every `close(reason:)` call site in the app + core and with docs/02 § BYE.
    public static let transientReasons: Set<String> = [
        timeoutReason,
        transportFailureReason,
        wakeReason,
        captureStallReason,
        encoderStallReason,
        noVideoReason,
        noFrameReason,
    ]

    // TCP options
    public static let tcpKeepaliveIdle = 2       // seconds
    public static let tcpKeepaliveInterval = 1   // seconds
    public static let tcpKeepaliveCount = 3
    public static let connectionDropTime = 5     // seconds — finite send timeout

    // Reconnect / viability (Phase 1)
    public static let viabilityDebounce: TimeInterval = 2.5
    // Source keep-alive tick (resends a keyframe on a static screen). Must be shorter
    // than noFrameDim so a still screen never dims.
    public static let keepAliveInterval: TimeInterval = 0.5
    public static let noFrameDim: TimeInterval = 1.5
    public static let noFrameTeardown: TimeInterval = 4.0
    public static let encoderWatchdog: TimeInterval = 1.0
    public static let encoderStallEscalate = 3
    public static let decoderRebuildLimit = 3
    public static let reconnectBackoff: [TimeInterval] = [0.25, 0.5, 1, 2, 4]
    public static let reconnectBackoffCap: TimeInterval = 5
    public static let pauseMax: TimeInterval = 90

    // Capture
    public static let getShareableTimeout: TimeInterval = 5.0
}
