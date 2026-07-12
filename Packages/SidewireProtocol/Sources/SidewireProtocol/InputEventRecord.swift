import Foundation

/// Input event kinds. Values are stable and platform-neutral (they do not change across a major
/// version). A Rust/Windows/Linux Display sends the same numeric codes.
public enum InputEventType: UInt8, Sendable {
    case mouseMove          = 1
    case mouseDown          = 2
    case mouseUp            = 3
    case rightMouseDown     = 4
    case rightMouseUp       = 5
    case scrollWheel        = 6
    case keyDown            = 7
    case keyUp              = 8
    case flagsChanged       = 9
    case mouseDragged       = 10
    case rightMouseDragged  = 11
}

/// The standard USB HID **boot-protocol keyboard modifier byte** (HID Usage Table, keyboard
/// page 0x07, usages 0xE0–0xE7). This is the platform-neutral modifier encoding on the wire —
/// each side translates it to/from its own OS modifier representation. Bit 0 (LSB) is Left
/// Control; bit 7 (MSB) is Right GUI.
public struct HIDModifier: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl  = HIDModifier(rawValue: 0x01) // HID usage 0xE0
    public static let leftShift    = HIDModifier(rawValue: 0x02) // HID usage 0xE1
    public static let leftAlt      = HIDModifier(rawValue: 0x04) // HID usage 0xE2
    public static let leftGUI      = HIDModifier(rawValue: 0x08) // HID usage 0xE3 (⌘ / Win)
    public static let rightControl = HIDModifier(rawValue: 0x10) // HID usage 0xE4
    public static let rightShift   = HIDModifier(rawValue: 0x20) // HID usage 0xE5
    public static let rightAlt     = HIDModifier(rawValue: 0x40) // HID usage 0xE6
    public static let rightGUI     = HIDModifier(rawValue: 0x80) // HID usage 0xE7
}

/// A fixed **32-byte** binary input event (replaces the old JSON-per-event encoding).
///
/// v2 makes the record **platform-neutral**: `keyCode` carries a **USB HID keyboard usage ID**
/// (HID Usage Table, Usage Page 0x07 — e.g. 0x04 = "a", 0x28 = Return, 0x52 = Up Arrow), NOT a
/// macOS virtual keycode; `modifiers` carries the **8-bit HID boot-protocol modifier byte** (see
/// `HIDModifier`), NOT raw NSEvent flags. Each endpoint translates its OS-native keycodes ⇄ HID
/// at capture/injection time. `Capabilities.inputMapping == "hid1"` declares this encoding.
///
/// Byte layout (integers big-endian, floats IEEE-754 big-endian):
///
/// ```
/// off  size field              notes
/// 0    1    eventType:UInt8     InputEventType raw value
/// 1    1    buttonNumber:UInt8  pointer button index (0 = left, 1 = right, …)
/// 2    1    clickCount:UInt8    click multiplicity (double-click = 2, …)
/// 3    1    modifiers:UInt8     HID boot-protocol modifier bitmask (see HIDModifier)
/// 4    8    reserved:UInt64     MUST be 0 on send, ignored on receive
/// 12   4    x:Float32           normalized 0..1 within the rendered video rect (top-left origin)
/// 16   4    y:Float32           normalized 0..1 (top-left origin)
/// 20   4    deltaX:Float32      scroll delta, wire unit = PIXELS (see docs/02 § INPUT)
/// 24   4    deltaY:Float32      scroll delta, wire unit = PIXELS
/// 28   2    keyCode:UInt16      USB HID keyboard usage ID (page 0x07); 0 = none / unmapped
/// 30   2    reserved:UInt16     MUST be 0 on send, ignored on receive
/// ```
public struct InputEventRecord: Sendable, Equatable {
    public var type: InputEventType
    public var buttonNumber: UInt8
    public var clickCount: UInt8
    /// HID boot-protocol modifier byte (see `HIDModifier`).
    public var modifiers: UInt8
    public var x: Float
    public var y: Float
    /// Scroll delta X — wire unit is pixels.
    public var deltaX: Float
    /// Scroll delta Y — wire unit is pixels.
    public var deltaY: Float
    /// USB HID keyboard usage ID (Usage Page 0x07). 0 = none / unmapped.
    public var keyCode: UInt16

    public init(type: InputEventType, buttonNumber: UInt8 = 0, clickCount: UInt8 = 0,
                modifiers: UInt8 = 0, x: Float = 0, y: Float = 0,
                deltaX: Float = 0, deltaY: Float = 0, keyCode: UInt16 = 0) {
        self.type = type
        self.buttonNumber = buttonNumber
        self.clickCount = clickCount
        self.modifiers = modifiers
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.keyCode = keyCode
    }

    public var encoded: Data {
        var d = Data(capacity: ProtocolConstants.inputRecordBytes)
        d.append(type.rawValue)
        d.append(buttonNumber)
        d.append(clickCount)
        d.append(modifiers)
        // 8 reserved bytes (was the v1 UInt64 modifierFlags field).
        for _ in 0..<8 { d.append(0) }
        ByteWriter.appendBEFloat(&d, x)
        ByteWriter.appendBEFloat(&d, y)
        ByteWriter.appendBEFloat(&d, deltaX)
        ByteWriter.appendBEFloat(&d, deltaY)
        ByteWriter.appendBE16(&d, keyCode)
        d.append(0); d.append(0) // reserved
        return d
    }

    public static func decode(from data: Data) -> InputEventRecord? {
        guard data.count >= ProtocolConstants.inputRecordBytes else { return nil }
        let b = data.startIndex
        guard let type = InputEventType(rawValue: data[b]) else { return nil }
        let buttonNumber = data[b + 1]
        let clickCount = data[b + 2]
        let modifiers = data[b + 3]
        // bytes 4..11 reserved (ignored)
        let x = ByteReader.beFloat(data, b + 12)
        let y = ByteReader.beFloat(data, b + 16)
        let deltaX = ByteReader.beFloat(data, b + 20)
        let deltaY = ByteReader.beFloat(data, b + 24)
        let keyCode = ByteReader.be16(data, b + 28)
        return InputEventRecord(type: type, buttonNumber: buttonNumber, clickCount: clickCount,
                                modifiers: modifiers, x: x, y: y,
                                deltaX: deltaX, deltaY: deltaY, keyCode: keyCode)
    }

    /// Decode a payload that may batch several 32-byte records.
    public static func decodeBatch(from data: Data) -> [InputEventRecord] {
        let stride = ProtocolConstants.inputRecordBytes
        guard data.count >= stride else { return [] }
        var result: [InputEventRecord] = []
        var offset = data.startIndex
        while offset + stride <= data.endIndex {
            if let rec = decode(from: data[offset ..< offset + stride]) { result.append(rec) }
            offset += stride
        }
        return result
    }
}
