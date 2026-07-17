import AppKit
import CoreGraphics
import os
import SidewireProtocol

/// Platform-neutral keyboard translation for protocol v2 (`Capabilities.inputMapping == "hid1"`).
///
/// The wire carries **USB HID keyboard usage IDs** (HID Usage Table, Usage Page 0x07) and the
/// **HID boot-protocol modifier byte**, never macOS virtual keycodes / NSEvent flags. This makes
/// the input contract identical for a Rust/Windows/Linux Display, which speaks HID natively.
///
/// - **Capture (Display → wire):** `hidUsage(fromMacVirtualKey:)`, `hidModifiers(from:)`.
/// - **Inject (wire → Source):** `macVirtualKey(fromHIDUsage:)`, `cgEventFlags(fromHIDModifiers:)`.
///
/// The keycode lookup tables (both directions) live in `SidewireProtocol.HIDKeyboardMap` as pure,
/// unit-testable data; this type wraps them with once-per-code logging and adds the Apple-only
/// pieces (NSEvent flags ⇄ HID modifier byte, CGEventFlags) that can't be a platform-neutral table.
/// Unmapped codes translate to 0 / nil (dropped, logged once per code).
enum KeyMapping {

    // MARK: - macOS virtual keycode ⇄ HID usage (USB HID keyboard page 0x07)

    /// macOS virtual keycode → HID usage. Returns 0 for an unmapped code (dropped upstream).
    static func hidUsage(fromMacVirtualKey keyCode: UInt16) -> UInt16 {
        if let hid = HIDKeyboardMap.hidUsage(fromMacVirtualKey: keyCode) { return hid }
        warnUnmapped(keyCode, isMac: true)
        return 0
    }

    /// HID usage → macOS virtual keycode. Returns nil for an unmapped usage (dropped upstream).
    static func macVirtualKey(fromHIDUsage usage: UInt16) -> UInt16? {
        if let mac = HIDKeyboardMap.macVirtualKey(fromHIDUsage: usage) { return mac }
        warnUnmapped(usage, isMac: false)
        return nil
    }

    // MARK: - Modifiers

    /// NSEvent device-independent modifier flags → the 8-bit HID boot-protocol modifier byte.
    /// NSEvent flags don't distinguish left/right, so we report the left-hand bit for each active
    /// modifier (sufficient to reconstruct CGEventFlags on the Source). Caps Lock is a toggle key,
    /// not a boot-modifier bit, so it is excluded here (it still crosses as a keyDown of usage 0x39).
    static func hidModifiers(from flags: NSEvent.ModifierFlags) -> UInt8 {
        var mods = HIDModifier()
        if flags.contains(.control) { mods.insert(.leftControl) }
        if flags.contains(.shift)   { mods.insert(.leftShift) }
        if flags.contains(.option)  { mods.insert(.leftAlt) }
        if flags.contains(.command) { mods.insert(.leftGUI) }
        return mods.rawValue
    }

    /// HID boot-protocol modifier byte → CGEventFlags for injection on the Source. Left and right
    /// variants collapse onto the single macOS device-independent flag.
    static func cgEventFlags(fromHIDModifiers modifiers: UInt8) -> CGEventFlags {
        let mods = HIDModifier(rawValue: modifiers)
        var flags = CGEventFlags()
        if !mods.isDisjoint(with: [.leftControl, .rightControl]) { flags.insert(.maskControl) }
        if !mods.isDisjoint(with: [.leftShift, .rightShift])     { flags.insert(.maskShift) }
        if !mods.isDisjoint(with: [.leftAlt, .rightAlt])         { flags.insert(.maskAlternate) }
        if !mods.isDisjoint(with: [.leftGUI, .rightGUI])         { flags.insert(.maskCommand) }
        return flags
    }

    // MARK: - Once-per-code diagnostics

    private static let log = Logger(subsystem: "com.kinocoder.sidewire", category: "input")
    private static let warnLock = NSLock()
    private static var warnedMac = Set<UInt16>()
    private static var warnedHID = Set<UInt16>()

    private static func warnUnmapped(_ code: UInt16, isMac: Bool) {
        warnLock.lock(); defer { warnLock.unlock() }
        let inserted = isMac ? warnedMac.insert(code).inserted : warnedHID.insert(code).inserted
        guard inserted else { return } // once per code
        let direction = isMac ? "mac→HID (virtual keycode)" : "HID→mac (usage id)"
        log.notice("unmapped key \(direction, privacy: .public) code=0x\(String(code, radix: 16), privacy: .public) → dropped")
    }
}
