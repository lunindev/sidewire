//! Canonical wire-protocol constants. Mirrors `ProtocolConstants.swift` and docs/02 § Constants.

/// Handshake magic string carried in HELLO.
pub const PROTOCOL_MAGIC: &str = "SIDEWIRE";

/// Protocol v2 major version. A peer accepts only an equal-`major` peer (v2 ↔ v2); a v1 peer is
/// rejected at HELLO. See docs/02 § Protocol evolution policy.
pub const PROTOCOL_MAJOR: u16 = 2;

/// Additive (informational) minor version — never gate behavior on it.
pub const PROTOCOL_MINOR: u16 = 0;

/// Fixed frame header size in bytes: `type(1) + flags(1) + reserved(2) + length(4) + seq(4)`.
pub const FRAME_HEADER_BYTES: usize = 12;

/// Reject any frame declaring a larger payload — guards against unbounded allocation from a
/// corrupt/hostile length. See docs/02 § Transport framing.
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// One binary INPUT event record size in bytes.
pub const INPUT_RECORD_BYTES: usize = 32;

/// VIDEO subheader size in bytes: `ltrToken(2) + flags(2) + pts(8)`.
pub const VIDEO_SUBHEADER_BYTES: usize = 12;

/// PING cadence — each peer sends a PING every 0.5 s.
pub const HEARTBEAT_INTERVAL_SECS: f64 = 0.5;

/// Max silence before declaring the peer dead (any inbound frame resets the watchdog).
pub const HEARTBEAT_TIMEOUT_SECS: f64 = 2.5;

/// Bonjour service type for discovery.
pub const BONJOUR_SERVICE_TYPE: &str = "_sidewire._tcp";

/// Fallback port for manual-IP Thunderbolt links. Normal operation advertises an ephemeral port.
pub const FALLBACK_PORT: u16 = 5005;
