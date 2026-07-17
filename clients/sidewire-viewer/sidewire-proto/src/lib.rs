//! Sidewire wire protocol (v2) — framing, JSON control messages, HID input records, video payload.
//!
//! A pure, no-crypto, no-IO port of the Swift `SidewireProtocol` package. The byte-exact
//! conformance target is [`../../../protocol-vectors`] (`frame`/`input`/`video`-vectors are
//! byte-exact; `message`-vectors are semantic) and the normative spec is `docs/02-protocol.md`.
//! Where prose and a golden vector disagree, the vector is correct by definition.

pub mod constants;
pub mod frame;
pub mod input;
pub mod message_type;
pub mod messages;
pub mod video;

pub use constants::*;
pub use frame::{encode as encode_frame, encode_typed, Frame, FrameParser, ParseError};
pub use input::{hid_modifier, InputEventRecord, InputEventType};
pub use message_type::{video_flags, MessageType};
pub use messages::{
    Capabilities, Config, DisplayInfo, Hello, HelloRejection, ProtocolVersion, ReasonMessage, Role,
    DEFAULT_INPUT_MAPPING,
};
pub use video::{CursorPayload, HeartbeatPayload, LtrAckPayload, VideoPayload};
