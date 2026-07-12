import Foundation

/// Canonical wire-protocol constants. See docs/02-protocol.md.
public enum ProtocolConstants {
    public static let magic = "SIDEWIRE"
    /// Protocol v2: certificate-based TLS 1.3 + channel-bound PIN proof replaces the v1
    /// PIN-derived TLS-PSK transport (docs/05, docs/09 §D11). A breaking wire change — v1
    /// peers are rejected at HELLO. Nothing shipped on v1, so there is no dual-stack.
    public static let major: UInt16 = 2
    public static let minor: UInt16 = 0

    /// Fixed frame header size in bytes: type(1) + flags(1) + reserved(2) + length(4) + seq(4).
    public static let frameHeaderBytes = 12

    /// Reject any frame claiming a larger payload — guards against unbounded allocation.
    public static let maxFrameBytes = 16 * 1024 * 1024

    /// Bonjour service type for discovery (changed from the old `_macdisplay._tcp`).
    public static let bonjourServiceType = "_sidewire._tcp"

    /// Fallback port for manual-IP Thunderbolt links. Normal operation advertises an
    /// ephemeral port via Bonjour.
    public static let fallbackPort: UInt16 = 5005

    /// One binary input event record size in bytes.
    public static let inputRecordBytes = 32
}
