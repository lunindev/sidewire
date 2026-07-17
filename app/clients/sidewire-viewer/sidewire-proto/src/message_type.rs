//! Wire message types and the VIDEO flag bits. Mirrors `MessageType.swift` and docs/02 § catalog.

/// Known wire message types. See docs/02 § Message catalog.
///
/// Unknown/reserved type bytes (including the reserved `0x70`–`0xFF` range and `0x11`/`0x42`) are
/// deliberately *not* represented here: they survive parsing as a raw [`crate::Frame`] with no
/// known [`MessageType`], and the consumer skips them via the frame length. This is what makes the
/// protocol forward-compatible.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MessageType {
    Hello = 0x01,
    HelloAck = 0x02,
    Config = 0x03,
    /// CPace PAKE share (`Ya`/`Yb`), 32 bytes; exchanged before HELLO on a first-time pairing.
    PairMsg = 0x04,
    /// CPace key-confirmation tag (`HMAC-SHA512`, 64 bytes).
    PairConfirm = 0x05,
    Video = 0x10,
    Audio = 0x11, // reserved
    Input = 0x20,
    /// The Source's pointer position over the streamed display, sent out-of-band so the pointer
    /// tracks at network latency instead of the video's decode lag. Payload is [`crate::CursorPayload`]
    /// (8 bytes: x, y as BE f32, normalized 0..1, top-left). The Source sets `showsCursor = false`,
    /// so this is the ONLY way the remote pointer reaches a Display — a client that skips it shows
    /// no cursor at all. Added after the golden vectors were frozen; not covered by them.
    Cursor = 0x21,
    Ping = 0x30,
    Pong = 0x31,
    RequestIdr = 0x40,
    LtrAck = 0x41,
    // 0x42 is reserved (was FEEDBACK; removed). Skippable like any unknown type.
    DisplayInfo = 0x50,
    Pause = 0x60,
    Resume = 0x61,
    Bye = 0x6F,
}

impl MessageType {
    /// Map a raw type byte to a known [`MessageType`], or `None` for an unknown/reserved type.
    pub fn from_u8(value: u8) -> Option<Self> {
        Some(match value {
            0x01 => Self::Hello,
            0x02 => Self::HelloAck,
            0x03 => Self::Config,
            0x04 => Self::PairMsg,
            0x05 => Self::PairConfirm,
            0x10 => Self::Video,
            0x11 => Self::Audio,
            0x20 => Self::Input,
            0x21 => Self::Cursor,
            0x30 => Self::Ping,
            0x31 => Self::Pong,
            0x40 => Self::RequestIdr,
            0x41 => Self::LtrAck,
            0x50 => Self::DisplayInfo,
            0x60 => Self::Pause,
            0x61 => Self::Resume,
            0x6F => Self::Bye,
            _ => return None,
        })
    }

    /// The raw wire byte for this type.
    pub fn as_u8(self) -> u8 {
        self as u8
    }
}

/// Flag bits for the VIDEO message (`flags` byte). Mirrors `VideoFlags`.
pub mod video_flags {
    /// IDR keyframe — payload begins with VPS/SPS/PPS parameter sets.
    pub const KEYFRAME: u8 = 0x01;
    /// Long-term-reference frame — reserved for future loss recovery (senders send 0 in v2).
    pub const LTR: u8 = 0x02;
    /// LTR-P (recovery) frame — reserved (senders send 0 in v2).
    pub const LTR_P: u8 = 0x04;
}
