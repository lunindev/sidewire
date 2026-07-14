import Foundation

/// Wire message types. See docs/02-protocol.md § Message catalog.
///
/// Unknown types (including anything in the reserved 0x70–0xFF range) must be
/// skipped via the frame's length prefix, never treated as fatal.
public enum MessageType: UInt8, Sendable {
    case hello       = 0x01
    case helloAck    = 0x02
    case config      = 0x03
    /// CPace PAKE message, exchanged BEFORE HELLO on a first-time pairing connection. Carries a
    /// 32-byte CPace public share (`Ya`/`Yb`). The Source (initiator) sends its share first, the
    /// Display (responder) replies with its own. See docs/05-security-and-pairing.md.
    case pairMsg     = 0x04
    /// CPace key-confirmation: each side sends `HMAC-SHA512(mac_key, lv_cat(ownShare, ownAD))`
    /// (a 64-byte tag) and verifies the peer's constant-time. A mismatch (wrong PIN) → BYE("auth").
    case pairConfirm = 0x05
    case video       = 0x10
    case audio       = 0x11   // reserved
    case input       = 0x20
    /// Cursor position (Source→Display), sent out-of-band on a high-frequency channel so the
    /// Display can warp its own native hardware cursor to track the user's hand at network
    /// latency instead of waiting for a cursor baked into the (encode→network→decode-lagged)
    /// video. Payload is `CursorPayload` (x,y normalized 0..1, TOP-LEFT origin, BE Float32).
    /// The Parsec/Moonlight "local cursor" technique. Skippable like any unknown type, so a
    /// peer that doesn't understand it simply ignores it.
    case cursor      = 0x21
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
