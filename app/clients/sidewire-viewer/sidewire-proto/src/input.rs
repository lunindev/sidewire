//! Fixed 32-byte binary INPUT records. Mirrors `InputEventRecord.swift` and docs/02 § INPUT.
//! Integers big-endian, floats IEEE-754 big-endian. Platform-neutral: `key_code` is a USB HID
//! keyboard usage (page 0x07), `modifiers` is the HID boot-protocol modifier byte.

use crate::constants::INPUT_RECORD_BYTES;

/// Input event kinds. Values are stable and platform-neutral (they do not change within a major
/// version). Mirrors `InputEventType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum InputEventType {
    MouseMove = 1,
    MouseDown = 2,
    MouseUp = 3,
    RightMouseDown = 4,
    RightMouseUp = 5,
    ScrollWheel = 6,
    KeyDown = 7,
    KeyUp = 8,
    FlagsChanged = 9,
    MouseDragged = 10,
    RightMouseDragged = 11,
}

impl InputEventType {
    pub fn from_u8(value: u8) -> Option<Self> {
        Some(match value {
            1 => Self::MouseMove,
            2 => Self::MouseDown,
            3 => Self::MouseUp,
            4 => Self::RightMouseDown,
            5 => Self::RightMouseUp,
            6 => Self::ScrollWheel,
            7 => Self::KeyDown,
            8 => Self::KeyUp,
            9 => Self::FlagsChanged,
            10 => Self::MouseDragged,
            11 => Self::RightMouseDragged,
            _ => return None,
        })
    }

    pub fn as_u8(self) -> u8 {
        self as u8
    }
}

/// The USB HID boot-protocol keyboard modifier byte (HID usages 0xE0–0xE7). Bit 0 is Left Control,
/// bit 7 is Right GUI. Mirrors `HIDModifier`.
pub mod hid_modifier {
    pub const LEFT_CONTROL: u8 = 0x01; // HID usage 0xE0
    pub const LEFT_SHIFT: u8 = 0x02; // HID usage 0xE1
    pub const LEFT_ALT: u8 = 0x04; // HID usage 0xE2
    pub const LEFT_GUI: u8 = 0x08; // HID usage 0xE3 (⌘ / Win)
    pub const RIGHT_CONTROL: u8 = 0x10; // HID usage 0xE4
    pub const RIGHT_SHIFT: u8 = 0x20; // HID usage 0xE5
    pub const RIGHT_ALT: u8 = 0x40; // HID usage 0xE6
    pub const RIGHT_GUI: u8 = 0x80; // HID usage 0xE7
}

/// A fixed **32-byte** binary input event. Byte layout (see docs/02 § INPUT):
///
/// ```text
/// off  size field              notes
/// 0    1    eventType:u8        InputEventType raw value
/// 1    1    buttonNumber:u8     pointer button index (0 = left, 1 = right, …)
/// 2    1    clickCount:u8       click multiplicity (double-click = 2, …)
/// 3    1    modifiers:u8        HID boot-protocol modifier bitmask
/// 4    8    reserved:u64        MUST be 0 on send, ignored on receive
/// 12   4    x:f32               normalized 0..1 within the rendered video rect (top-left origin)
/// 16   4    y:f32               normalized 0..1 (top-left origin)
/// 20   4    deltaX:f32          scroll delta, wire unit = PIXELS
/// 24   4    deltaY:f32          scroll delta, wire unit = PIXELS
/// 28   2    keyCode:u16         USB HID keyboard usage ID (page 0x07); 0 = none / unmapped
/// 30   2    reserved:u16        MUST be 0 on send, ignored on receive
/// ```
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InputEventRecord {
    pub event_type: InputEventType,
    pub button_number: u8,
    pub click_count: u8,
    /// HID boot-protocol modifier byte (see [`hid_modifier`]).
    pub modifiers: u8,
    pub x: f32,
    pub y: f32,
    /// Scroll delta X — wire unit is pixels.
    pub delta_x: f32,
    /// Scroll delta Y — wire unit is pixels.
    pub delta_y: f32,
    /// USB HID keyboard usage ID (page 0x07). 0 = none / unmapped.
    pub key_code: u16,
}

impl InputEventRecord {
    /// Construct a record with sensible defaults for the unused fields.
    pub fn new(event_type: InputEventType) -> Self {
        Self {
            event_type,
            button_number: 0,
            click_count: 0,
            modifiers: 0,
            x: 0.0,
            y: 0.0,
            delta_x: 0.0,
            delta_y: 0.0,
            key_code: 0,
        }
    }

    /// Encode to the fixed 32-byte record.
    pub fn encode(&self) -> [u8; INPUT_RECORD_BYTES] {
        let mut d = [0u8; INPUT_RECORD_BYTES];
        d[0] = self.event_type.as_u8();
        d[1] = self.button_number;
        d[2] = self.click_count;
        d[3] = self.modifiers;
        // bytes 4..12 reserved (zero)
        d[12..16].copy_from_slice(&self.x.to_be_bytes());
        d[16..20].copy_from_slice(&self.y.to_be_bytes());
        d[20..24].copy_from_slice(&self.delta_x.to_be_bytes());
        d[24..28].copy_from_slice(&self.delta_y.to_be_bytes());
        d[28..30].copy_from_slice(&self.key_code.to_be_bytes());
        // bytes 30..32 reserved (zero)
        d
    }

    /// Decode a single 32-byte record. Returns `None` if too short or the event type is unknown.
    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < INPUT_RECORD_BYTES {
            return None;
        }
        let event_type = InputEventType::from_u8(data[0])?;
        Some(Self {
            event_type,
            button_number: data[1],
            click_count: data[2],
            modifiers: data[3],
            // bytes 4..12 reserved (ignored)
            x: f32::from_be_bytes([data[12], data[13], data[14], data[15]]),
            y: f32::from_be_bytes([data[16], data[17], data[18], data[19]]),
            delta_x: f32::from_be_bytes([data[20], data[21], data[22], data[23]]),
            delta_y: f32::from_be_bytes([data[24], data[25], data[26], data[27]]),
            key_code: u16::from_be_bytes([data[28], data[29]]),
        })
    }

    /// Decode a payload that may batch several 32-byte records.
    pub fn decode_batch(data: &[u8]) -> Vec<Self> {
        let mut out = Vec::new();
        let mut offset = 0;
        while offset + INPUT_RECORD_BYTES <= data.len() {
            if let Some(rec) = Self::decode(&data[offset..offset + INPUT_RECORD_BYTES]) {
                out.push(rec);
            }
            offset += INPUT_RECORD_BYTES;
        }
        out
    }
}
