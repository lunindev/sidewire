//! JSON control messages (cold path): HELLO, CONFIG, DISPLAY_INFO, BYE, plus `Role`.
//! Mirrors `Messages.swift` / `Role.swift` and `protocol-vectors/message-vectors.json`.
//!
//! Evolution policy (docs/02 § Protocol evolution policy): unknown JSON fields are ignored on
//! decode (serde default — no `deny_unknown_fields`); fields beyond the v2 required set are
//! optional-with-defaults (`capabilities.inputMapping` ⇒ `"hid1"`, `config.hiDPI` ⇒ `true`).

use serde::{Deserialize, Deserializer, Serialize};

use crate::constants::{PROTOCOL_MAGIC, PROTOCOL_MAJOR, PROTOCOL_MINOR};

/// The role a peer plays in a session. Travels on the wire in HELLO. Mirrors `Role`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// Shares this machine's screen: creates a virtual display, captures and encodes it.
    Source,
    /// Uses this machine as a monitor: decodes and presents, forwards keyboard/mouse.
    Display,
}

impl Role {
    /// The complementary role a valid peer must have.
    pub fn opposite(self) -> Role {
        match self {
            Role::Source => Role::Display,
            Role::Display => Role::Source,
        }
    }
}

/// The only input mapping defined in v2 (platform-neutral USB-HID usages + HID modifier byte).
pub const DEFAULT_INPUT_MAPPING: &str = "hid1";

fn default_input_mapping() -> String {
    DEFAULT_INPUT_MAPPING.to_string()
}

fn default_true() -> bool {
    true
}

/// Deserialize an optional-with-default field, tolerating an explicit JSON `null` (mapped to the
/// default) as well as an absent key — matching the Swift decoders (`decodeIfPresent` / `Bool?`),
/// which read `null` as the default. Per the evolution policy these fields are
/// "optional-with-defaults", so a foreign encoder that writes `null` is accepted, not rejected.
/// (`#[serde(default)]` alone only covers an *absent* key; a present `null` would otherwise fail
/// the whole message decode.)
fn de_input_mapping<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_else(default_input_mapping))
}

fn de_hidpi<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(Option::<bool>::deserialize(d)?.unwrap_or_else(default_true))
}

/// Advertised capabilities exchanged in HELLO. Mirrors `Capabilities`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    /// Video codecs in preference order, e.g. `["hevc", "h264"]`.
    pub video_codecs: Vec<String>,
    pub max_width: i64,
    pub max_height: i64,
    pub max_fps: i64,
    pub ltr: bool,
    pub audio: bool,
    pub hdr: bool,
    /// The wire input-event encoding this peer speaks. Always `"hid1"` in v2. Optional-with-default
    /// on decode (absent ⇒ `"hid1"`), but always sent.
    #[serde(
        default = "default_input_mapping",
        deserialize_with = "de_input_mapping"
    )]
    pub input_mapping: String,
}

impl Capabilities {
    /// Construct capabilities with the default input mapping (`"hid1"`).
    pub fn new(
        video_codecs: Vec<String>,
        max_width: i64,
        max_height: i64,
        max_fps: i64,
        ltr: bool,
        audio: bool,
        hdr: bool,
    ) -> Self {
        Self {
            video_codecs,
            max_width,
            max_height,
            max_fps,
            ltr,
            audio,
            hdr,
            input_mapping: default_input_mapping(),
        }
    }
}

/// Protocol version (major/minor). Mirrors `ProtocolVersion`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
}

impl ProtocolVersion {
    pub const CURRENT: ProtocolVersion = ProtocolVersion {
        major: PROTOCOL_MAJOR,
        minor: PROTOCOL_MINOR,
    };
}

impl Default for ProtocolVersion {
    fn default() -> Self {
        Self::CURRENT
    }
}

/// First message each peer sends after TLS/pairing is ready. Mirrors `Hello`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    pub magic: String,
    pub version: ProtocolVersion,
    pub role: Role,
    pub device_id: String,
    pub device_name: String,
    pub session_id: String,
    pub capabilities: Capabilities,
}

impl Hello {
    /// Construct a HELLO for this device with the current protocol version + magic.
    pub fn new(
        role: Role,
        device_id: impl Into<String>,
        device_name: impl Into<String>,
        session_id: impl Into<String>,
        capabilities: Capabilities,
    ) -> Self {
        Self {
            magic: PROTOCOL_MAGIC.to_string(),
            version: ProtocolVersion::CURRENT,
            role,
            device_id: device_id.into(),
            device_name: device_name.into(),
            session_id: session_id.into(),
            capabilities,
        }
    }

    /// Validate a received HELLO against our own role. `None` = accepted. Mirrors `Hello.validate`.
    pub fn validate(&self, local_role: Role) -> Option<HelloRejection> {
        if self.magic != PROTOCOL_MAGIC {
            return Some(HelloRejection::BadMagic);
        }
        if self.version.major != PROTOCOL_MAJOR {
            return Some(HelloRejection::ProtocolMismatch);
        }
        if self.role != local_role.opposite() {
            return Some(HelloRejection::RoleConflict);
        }
        None
    }
}

/// Reason a received HELLO is rejected. The `reason()` string is what the peer sends in `BYE`.
/// Mirrors `HelloRejection` (note `BadMagic`'s reason string is `"badMagic"`, matching the Swift
/// enum's raw value — the `Session` sends `rejection.rawValue`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelloRejection {
    BadMagic,
    ProtocolMismatch,
    RoleConflict,
}

impl HelloRejection {
    /// The BYE reason token this rejection produces.
    pub fn reason(self) -> &'static str {
        match self {
            HelloRejection::BadMagic => "badMagic",
            HelloRejection::ProtocolMismatch => "protocol",
            HelloRejection::RoleConflict => "role",
        }
    }
}

/// The negotiated streaming configuration, computed by the source. Mirrors `Config`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub codec: String,
    pub width: i64,
    pub height: i64,
    pub fps: i64,
    pub ltr: bool,
    pub bitrate_start_bps: i64,
    pub bitrate_min_bps: i64,
    pub bitrate_max_bps: i64,
    /// Whether the source creates the virtual display HiDPI (2×) vs standard (1×).
    /// Optional-with-default per the evolution policy: absent ⇒ `true` (the pre-6.2 behavior).
    #[serde(
        rename = "hiDPI",
        default = "default_true",
        deserialize_with = "de_hidpi"
    )]
    pub hi_dpi: bool,
}

/// The display's native panel description, sent right after HELLO_ACK. Mirrors `DisplayInfo`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayInfo {
    pub width: i64,
    pub height: i64,
    pub scale_factor: f64,
    pub refresh_rate: f64,
    pub name: String,
}

/// Reason carried by PAUSE / BYE. Mirrors `ReasonMessage`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReasonMessage {
    pub reason: String,
}

impl ReasonMessage {
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }
}
