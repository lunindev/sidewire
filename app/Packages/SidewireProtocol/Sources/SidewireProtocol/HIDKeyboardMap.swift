import Foundation

/// Reference **macOS virtual keycode ⇄ USB HID keyboard usage** table (HID Usage Table, keyboard
/// page 0x07). This is pure integer data — no Apple imports — so it lives in the platform-neutral
/// protocol package as conformance material and is unit-testable under `swift test`. The macOS app
/// (`Sidewire/Input/KeyMapping.swift`) forwards its keycode translation here and adds the
/// genuinely Apple-only pieces (NSEvent flags ⇄ HID modifier byte, CGEventFlags).
///
/// A foreign (Windows/Linux) Display maps ITS own OS keycodes to the same HID usages; only the
/// macOS Source needs this specific table. It is the same canonical data Chromium's
/// `keyboard_code_conversion_mac` / DOM keycode-converter tables encode. It covers the full
/// ANSI/ISO/JIS sets: letters, digits, punctuation, F1–F20, keypad, arrows, navigation, modifiers,
/// and the representable media (volume) keys. It is a **bijection** over the mapped set, so
/// `macVirtualKey(fromHIDUsage: hidUsage(fromMacVirtualKey: k)!) == k` for every mapped `k`.
public enum HIDKeyboardMap {

    /// macOS `kVK_*` virtual keycode → HID keyboard usage ID.
    public static let macVirtualToHID: [UInt16: UInt16] = [
        // Letters
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A,
        0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11,
        0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18,
        0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        // Number row 1..0
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24,
        0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        // Whitespace / editing / punctuation
        0x24: 0x28, // Return
        0x35: 0x29, // Escape
        0x33: 0x2A, // Delete (Backspace)
        0x30: 0x2B, // Tab
        0x31: 0x2C, // Space
        0x1B: 0x2D, // - _
        0x18: 0x2E, // = +
        0x21: 0x2F, // [ {
        0x1E: 0x30, // ] }
        0x2A: 0x31, // \ |
        0x29: 0x33, // ; :
        0x27: 0x34, // ' "
        0x32: 0x35, // ` ~
        0x2B: 0x36, // , <
        0x2F: 0x37, // . >
        0x2C: 0x38, // / ?
        0x39: 0x39, // Caps Lock
        // Function keys F1–F12
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40,
        0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
        // Navigation / editing cluster
        0x72: 0x49, // Help → Insert
        0x73: 0x4A, // Home
        0x74: 0x4B, // Page Up
        0x75: 0x4C, // Forward Delete
        0x77: 0x4D, // End
        0x79: 0x4E, // Page Down
        0x7C: 0x4F, // Right Arrow
        0x7B: 0x50, // Left Arrow
        0x7D: 0x51, // Down Arrow
        0x7E: 0x52, // Up Arrow
        // Keypad
        0x47: 0x53, // Clear / Num Lock
        0x4B: 0x54, // /
        0x43: 0x55, // *
        0x4E: 0x56, // -
        0x45: 0x57, // +
        0x4C: 0x58, // Enter
        0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F,
        0x5B: 0x60, 0x5C: 0x61, 0x52: 0x62, // 7,8,9,0
        0x41: 0x63, // .
        // ISO / non-US / application
        0x0A: 0x64, // ISO Section / non-US \|
        0x6E: 0x65, // Application (Menu)
        0x51: 0x67, // Keypad =
        // Function keys F13–F20
        0x69: 0x68, 0x6B: 0x69, 0x71: 0x6A, 0x6A: 0x6B, 0x40: 0x6C, 0x4F: 0x6D, 0x50: 0x6E,
        0x5A: 0x6F,
        // Media / volume (representable on the HID keyboard page)
        0x4A: 0x7F, // Mute
        0x48: 0x80, // Volume Up
        0x49: 0x81, // Volume Down
        // JIS
        0x5F: 0x85, // Keypad Comma
        0x5E: 0x87, // International1 (RO)
        0x5D: 0x89, // International3 (¥)
        0x68: 0x90, // Lang1 (Kana)
        0x66: 0x91, // Lang2 (Eisu)
        // Modifiers (HID usages 0xE0–0xE7)
        0x3B: 0xE0, // Left Control
        0x38: 0xE1, // Left Shift
        0x3A: 0xE2, // Left Option (Alt)
        0x37: 0xE3, // Left Command (GUI)
        0x3E: 0xE4, // Right Control
        0x3C: 0xE5, // Right Shift
        0x3D: 0xE6, // Right Option (Alt)
        0x36: 0xE7, // Right Command (GUI)
    ]

    /// HID usage → macOS virtual keycode, derived once (the inverse of `macVirtualToHID`).
    public static let hidToMacVirtual: [UInt16: UInt16] = {
        var m = [UInt16: UInt16](minimumCapacity: macVirtualToHID.count)
        for (mac, hid) in macVirtualToHID { m[hid] = mac }
        return m
    }()

    /// macOS virtual keycode → HID usage, or nil if unmapped.
    public static func hidUsage(fromMacVirtualKey keyCode: UInt16) -> UInt16? {
        macVirtualToHID[keyCode]
    }

    /// HID usage → macOS virtual keycode, or nil if unmapped.
    public static func macVirtualKey(fromHIDUsage usage: UInt16) -> UInt16? {
        hidToMacVirtual[usage]
    }
}
