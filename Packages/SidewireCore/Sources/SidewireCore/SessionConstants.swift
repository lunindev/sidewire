import Foundation

/// Session / timing constants. Defined once here (see docs/03-reliability.md § Constants).
/// Many are consumed by the Phase 1 reliability engine; they are defined now so there is
/// a single source of truth and Phase 0 code can already reference the ones it needs.
public enum SessionConstants {
    // Heartbeat (Phase 1)
    public static let heartbeatInterval: TimeInterval = 0.5
    public static let heartbeatTimeout: TimeInterval = 2.5
    public static let heartbeatMissLimit = 5

    // TCP options
    public static let tcpKeepaliveIdle = 2       // seconds
    public static let tcpKeepaliveInterval = 1   // seconds
    public static let tcpKeepaliveCount = 3
    public static let connectionDropTime = 5     // seconds — finite send timeout

    // Reconnect / viability (Phase 1)
    public static let viabilityDebounce: TimeInterval = 2.5
    public static let noFrameDim: TimeInterval = 0.75
    public static let noFrameTeardown: TimeInterval = 3.0
    public static let encoderWatchdog: TimeInterval = 1.0
    public static let encoderStallEscalate = 3
    public static let decoderRebuildLimit = 3
    public static let reconnectBackoff: [TimeInterval] = [0.25, 0.5, 1, 2, 4]
    public static let reconnectBackoffCap: TimeInterval = 5
    public static let pauseMax: TimeInterval = 90

    // Capture
    public static let getShareableTimeout: TimeInterval = 5.0
}
