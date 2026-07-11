import Foundation

/// The role a peer plays in a session. Travels on the wire in the HELLO message.
public enum Role: String, Codable, Sendable, Hashable {
    /// Shares this Mac's screen: creates a virtual display, captures and encodes it.
    case source
    /// Uses this Mac as a monitor: decodes and presents, forwards keyboard/mouse.
    case display

    /// The complementary role a valid peer must have.
    public var opposite: Role { self == .source ? .display : .source }
}
