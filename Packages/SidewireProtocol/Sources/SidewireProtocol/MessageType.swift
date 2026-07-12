import Foundation

/// Wire message types. See docs/02-protocol.md § Message catalog.
///
/// Unknown types (including anything in the reserved 0x70–0xFF range) must be
/// skipped via the frame's length prefix, never treated as fatal.
public enum MessageType: UInt8, Sendable {
    case hello       = 0x01
    case helloAck    = 0x02
    case config      = 0x03
    /// Pairing PIN-proof (channel-bound HMAC), exchanged BEFORE HELLO on a first-time
    /// pairing connection. Source sends its proof first, Display replies with its own.
    /// See docs/05-security-and-pairing.md. Payload = 32-byte HMAC-SHA256.
    case pairProof   = 0x04
    /// Pairing acknowledgement: Source → Display, empty payload, sent after the Source has
    /// verified the Display's proof. Confirms mutual success so the Display proceeds to HELLO.
    case pairAck     = 0x05
    case video       = 0x10
    case audio       = 0x11   // reserved
    case input       = 0x20
    case ping        = 0x30
    case pong        = 0x31
    case requestIDR  = 0x40
    case ltrAck      = 0x41
    // 0x42 is reserved (was FEEDBACK in early v2 drafts; removed — adaptive bitrate is
    // RTT-driven and the message was never sent). Skippable like any unknown type.
    case displayInfo = 0x50
    case pause       = 0x60
    case resume      = 0x61
    case bye         = 0x6F
}

/// Flag bits for the VIDEO message (`flags` byte).
public struct VideoFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// IDR keyframe — payload begins with VPS/SPS/PPS parameter sets.
    public static let keyframe = VideoFlags(rawValue: 0x01)
    /// This frame was marked as a long-term reference; `ltrToken` is valid.
    public static let ltr      = VideoFlags(rawValue: 0x02)
    /// A P-frame referencing a known-good acknowledged LTR frame (recovery frame).
    public static let ltrP     = VideoFlags(rawValue: 0x04)
}
