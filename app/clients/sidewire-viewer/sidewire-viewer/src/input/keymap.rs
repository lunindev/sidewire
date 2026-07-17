//! winit `KeyCode` → **USB HID keyboard usage** (Usage Page 0x07) mapping.
//!
//! This is the Rust Display's counterpart to the macOS Source's
//! `Packages/SidewireProtocol/Sources/SidewireProtocol/HIDKeyboardMap.swift`. Both sides derive
//! their tables from the **same** USB HID Usage Table, so for every physical key that both map, the
//! emitted HID usage is identical (e.g. `KeyA` → `0x04`, `Enter` → `0x28`, `ArrowUp` → `0x52`,
//! `ShiftLeft` → `0xE1`, `Digit1` → `0x1E`). This is the platform-neutral `"hid1"` input encoding of
//! docs/02 § INPUT: the wire only ever carries HID usages, never OS keycodes.
//!
//! A key with no HID usage returns [`None`] and is **dropped** by the caller — never sent as an
//! ambiguous `0` (docs/02 § INPUT: "A key with no HID mapping is dropped by the sender").

use winit::keyboard::KeyCode;

/// Map a winit physical [`KeyCode`] to its USB HID keyboard usage ID (Usage Page 0x07), or [`None`]
/// if the key has no representable HID usage (dropped by the caller).
///
/// The mapped set matches `HIDKeyboardMap.swift` (the macOS reference): letters, digits, the number
/// row, punctuation, F1–F20, keypad, arrows, the navigation cluster, whitespace/editing keys,
/// CapsLock, the modifier keys (0xE0–0xE7), the representable media/volume keys, and the JIS/ISO
/// international keys. Keys winit can name but that have no HID keyboard-page usage in that set
/// (e.g. `PrintScreen`, `Pause`, `Fn`, browser/media transport keys) return `None`.
pub fn hid_usage(key: KeyCode) -> Option<u16> {
    use KeyCode::*;
    Some(match key {
        // -- Letters (HID 0x04–0x1D) --
        KeyA => 0x04,
        KeyB => 0x05,
        KeyC => 0x06,
        KeyD => 0x07,
        KeyE => 0x08,
        KeyF => 0x09,
        KeyG => 0x0A,
        KeyH => 0x0B,
        KeyI => 0x0C,
        KeyJ => 0x0D,
        KeyK => 0x0E,
        KeyL => 0x0F,
        KeyM => 0x10,
        KeyN => 0x11,
        KeyO => 0x12,
        KeyP => 0x13,
        KeyQ => 0x14,
        KeyR => 0x15,
        KeyS => 0x16,
        KeyT => 0x17,
        KeyU => 0x18,
        KeyV => 0x19,
        KeyW => 0x1A,
        KeyX => 0x1B,
        KeyY => 0x1C,
        KeyZ => 0x1D,

        // -- Number row 1..0 (HID 0x1E–0x27) --
        Digit1 => 0x1E,
        Digit2 => 0x1F,
        Digit3 => 0x20,
        Digit4 => 0x21,
        Digit5 => 0x22,
        Digit6 => 0x23,
        Digit7 => 0x24,
        Digit8 => 0x25,
        Digit9 => 0x26,
        Digit0 => 0x27,

        // -- Whitespace / editing / punctuation (HID 0x28–0x39) --
        Enter => 0x28,
        Escape => 0x29,
        Backspace => 0x2A,
        Tab => 0x2B,
        Space => 0x2C,
        Minus => 0x2D,        // - _
        Equal => 0x2E,        // = +
        BracketLeft => 0x2F,  // [ {
        BracketRight => 0x30, // ] }
        Backslash => 0x31,    // \ |
        Semicolon => 0x33,    // ; :
        Quote => 0x34,        // ' "
        Backquote => 0x35,    // ` ~
        Comma => 0x36,        // , <
        Period => 0x37,       // . >
        Slash => 0x38,        // / ?
        CapsLock => 0x39,     // not a modifier bit — a normal key (docs/02 § INPUT)

        // -- Function keys F1–F12 (HID 0x3A–0x45) --
        F1 => 0x3A,
        F2 => 0x3B,
        F3 => 0x3C,
        F4 => 0x3D,
        F5 => 0x3E,
        F6 => 0x3F,
        F7 => 0x40,
        F8 => 0x41,
        F9 => 0x42,
        F10 => 0x43,
        F11 => 0x44,
        F12 => 0x45,

        // -- Navigation / editing cluster (HID 0x49–0x52) --
        Insert => 0x49,
        Home => 0x4A,
        PageUp => 0x4B,
        Delete => 0x4C, // forward delete (winit `Backspace` is the backspacing key, HID 0x2A)
        End => 0x4D,
        PageDown => 0x4E,
        ArrowRight => 0x4F,
        ArrowLeft => 0x50,
        ArrowDown => 0x51,
        ArrowUp => 0x52,

        // -- Keypad (HID 0x53–0x63) --
        NumLock => 0x53, // Num Lock / Clear
        NumpadDivide => 0x54,
        NumpadMultiply => 0x55,
        NumpadSubtract => 0x56,
        NumpadAdd => 0x57,
        NumpadEnter => 0x58,
        Numpad1 => 0x59,
        Numpad2 => 0x5A,
        Numpad3 => 0x5B,
        Numpad4 => 0x5C,
        Numpad5 => 0x5D,
        Numpad6 => 0x5E,
        Numpad7 => 0x5F,
        Numpad8 => 0x60,
        Numpad9 => 0x61,
        Numpad0 => 0x62,
        NumpadDecimal => 0x63,

        // -- ISO / non-US / application (HID 0x64, 0x65, 0x67) --
        IntlBackslash => 0x64, // ISO Section / non-US \|
        ContextMenu => 0x65,   // Application (Menu)
        NumpadEqual => 0x67,   // Keypad =

        // -- Function keys F13–F20 (HID 0x68–0x6F) --
        F13 => 0x68,
        F14 => 0x69,
        F15 => 0x6A,
        F16 => 0x6B,
        F17 => 0x6C,
        F18 => 0x6D,
        F19 => 0x6E,
        F20 => 0x6F,

        // -- Keypad comma + JIS/international (HID 0x85, 0x87, 0x89, 0x90, 0x91) --
        NumpadComma => 0x85, // Keypad Comma
        IntlRo => 0x87,      // International1 (RO)
        IntlYen => 0x89,     // International3 (¥)
        Lang1 => 0x90,       // LANG1 (Hangul / Kana)
        Lang2 => 0x91,       // LANG2 (Hanja / Eisu)

        // -- Media / volume representable on the HID keyboard page (HID 0x7F–0x81) --
        AudioVolumeMute => 0x7F,
        AudioVolumeUp => 0x80,
        AudioVolumeDown => 0x81,

        // -- Modifier keys (HID 0xE0–0xE7). GUI = ⌘ on macOS / Win key elsewhere. --
        ControlLeft => 0xE0,
        ShiftLeft => 0xE1,
        AltLeft => 0xE2,
        SuperLeft => 0xE3,
        ControlRight => 0xE4,
        ShiftRight => 0xE5,
        AltRight => 0xE6,
        SuperRight => 0xE7,

        // Everything else has no HID keyboard-page usage in the reference set → drop it.
        _ => return None,
    })
}

/// True if `usage` is a HID modifier usage (0xE0–0xE7). Such a key press is reported on the wire as
/// a `flagsChanged` event (docs/02 § INPUT), not a `keyDown`/`keyUp`.
pub fn is_modifier_usage(usage: u16) -> bool {
    (0xE0..=0xE7).contains(&usage)
}

/// True if `usage` is the Left/Right GUI (⌘/Win) modifier — the modifier reserved for local
/// shortcuts, so its own press/release and any combo held with it stay on the Display and are never
/// forwarded (mirrors `InputCapture.swift`'s Command-key handling).
pub fn is_gui_usage(usage: u16) -> bool {
    usage == 0xE3 || usage == 0xE7
}

/// The Escape HID usage (0x29) — reserved-local: Escape toggles out of fullscreen and is never
/// forwarded (mirrors `InputCapture.swift`, so the user always keeps a way out of immersive mode).
pub const ESCAPE_USAGE: u16 = 0x29;

#[cfg(test)]
mod tests {
    use super::*;
    use winit::keyboard::KeyCode;

    /// The emitted HID usages MUST equal `HIDKeyboardMap.swift`'s for the corresponding physical key
    /// (both derive from the same USB HID Usage Table). A representative cross-section is asserted
    /// here; the same values appear in the Swift `HIDKeyboardMap` unit tests / `protocol-vectors`.
    #[test]
    fn matches_swift_hid_usages() {
        // Letters 0x04..0x1D.
        assert_eq!(hid_usage(KeyCode::KeyA), Some(0x04));
        assert_eq!(hid_usage(KeyCode::KeyZ), Some(0x1D));
        assert_eq!(hid_usage(KeyCode::KeyM), Some(0x10));
        // Number row: Digit1=0x1E .. Digit9=0x26, Digit0=0x27.
        assert_eq!(hid_usage(KeyCode::Digit1), Some(0x1E));
        assert_eq!(hid_usage(KeyCode::Digit9), Some(0x26));
        assert_eq!(hid_usage(KeyCode::Digit0), Some(0x27));
        // Whitespace / editing.
        assert_eq!(hid_usage(KeyCode::Enter), Some(0x28));
        assert_eq!(hid_usage(KeyCode::Escape), Some(0x29));
        assert_eq!(hid_usage(KeyCode::Backspace), Some(0x2A));
        assert_eq!(hid_usage(KeyCode::Tab), Some(0x2B));
        assert_eq!(hid_usage(KeyCode::Space), Some(0x2C));
        assert_eq!(hid_usage(KeyCode::CapsLock), Some(0x39));
        // Arrows: Right=0x4F, Left=0x50, Down=0x51, Up=0x52.
        assert_eq!(hid_usage(KeyCode::ArrowRight), Some(0x4F));
        assert_eq!(hid_usage(KeyCode::ArrowLeft), Some(0x50));
        assert_eq!(hid_usage(KeyCode::ArrowDown), Some(0x51));
        assert_eq!(hid_usage(KeyCode::ArrowUp), Some(0x52));
        // Function keys F1=0x3A .. F12=0x45 (and F20=0x6F).
        assert_eq!(hid_usage(KeyCode::F1), Some(0x3A));
        assert_eq!(hid_usage(KeyCode::F12), Some(0x45));
        assert_eq!(hid_usage(KeyCode::F20), Some(0x6F));
        // Navigation cluster + forward delete.
        assert_eq!(hid_usage(KeyCode::Insert), Some(0x49));
        assert_eq!(hid_usage(KeyCode::Home), Some(0x4A));
        assert_eq!(hid_usage(KeyCode::PageUp), Some(0x4B));
        assert_eq!(hid_usage(KeyCode::Delete), Some(0x4C));
        assert_eq!(hid_usage(KeyCode::End), Some(0x4D));
        assert_eq!(hid_usage(KeyCode::PageDown), Some(0x4E));
        // Keypad.
        assert_eq!(hid_usage(KeyCode::Numpad0), Some(0x62));
        assert_eq!(hid_usage(KeyCode::NumpadEnter), Some(0x58));
        assert_eq!(hid_usage(KeyCode::NumpadDecimal), Some(0x63));
        // Media / volume.
        assert_eq!(hid_usage(KeyCode::AudioVolumeMute), Some(0x7F));
        assert_eq!(hid_usage(KeyCode::AudioVolumeUp), Some(0x80));
        assert_eq!(hid_usage(KeyCode::AudioVolumeDown), Some(0x81));
        // Modifiers 0xE0..0xE7 (left AND right).
        assert_eq!(hid_usage(KeyCode::ControlLeft), Some(0xE0));
        assert_eq!(hid_usage(KeyCode::ShiftLeft), Some(0xE1));
        assert_eq!(hid_usage(KeyCode::AltLeft), Some(0xE2));
        assert_eq!(hid_usage(KeyCode::SuperLeft), Some(0xE3));
        assert_eq!(hid_usage(KeyCode::ControlRight), Some(0xE4));
        assert_eq!(hid_usage(KeyCode::ShiftRight), Some(0xE5));
        assert_eq!(hid_usage(KeyCode::AltRight), Some(0xE6));
        assert_eq!(hid_usage(KeyCode::SuperRight), Some(0xE7));
    }

    /// Every letter A..Z maps to the contiguous HID block 0x04..0x1D, in order.
    #[test]
    fn letters_are_contiguous() {
        let letters = [
            KeyCode::KeyA,
            KeyCode::KeyB,
            KeyCode::KeyC,
            KeyCode::KeyD,
            KeyCode::KeyE,
            KeyCode::KeyF,
            KeyCode::KeyG,
            KeyCode::KeyH,
            KeyCode::KeyI,
            KeyCode::KeyJ,
            KeyCode::KeyK,
            KeyCode::KeyL,
            KeyCode::KeyM,
            KeyCode::KeyN,
            KeyCode::KeyO,
            KeyCode::KeyP,
            KeyCode::KeyQ,
            KeyCode::KeyR,
            KeyCode::KeyS,
            KeyCode::KeyT,
            KeyCode::KeyU,
            KeyCode::KeyV,
            KeyCode::KeyW,
            KeyCode::KeyX,
            KeyCode::KeyY,
            KeyCode::KeyZ,
        ];
        for (i, k) in letters.iter().enumerate() {
            assert_eq!(hid_usage(*k), Some(0x04 + i as u16));
        }
    }

    /// An unmapped key returns `None` (dropped, never sent as an ambiguous 0).
    #[test]
    fn unmapped_keys_return_none() {
        assert_eq!(hid_usage(KeyCode::PrintScreen), None);
        assert_eq!(hid_usage(KeyCode::Pause), None);
        assert_eq!(hid_usage(KeyCode::Fn), None);
        assert_eq!(hid_usage(KeyCode::MediaPlayPause), None);
        assert_eq!(hid_usage(KeyCode::BrowserBack), None);
    }

    #[test]
    fn modifier_and_gui_predicates() {
        assert!(is_modifier_usage(0xE0));
        assert!(is_modifier_usage(0xE7));
        assert!(!is_modifier_usage(0x04));
        assert!(is_gui_usage(0xE3));
        assert!(is_gui_usage(0xE7));
        assert!(!is_gui_usage(0xE1)); // shift is not GUI
    }
}
