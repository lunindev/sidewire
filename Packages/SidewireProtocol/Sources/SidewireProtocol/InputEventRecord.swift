import Foundation

/// Input event kinds. Values match the previous app so injection/capture logic ports directly.
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

/// A fixed 32-byte binary input event (replaces the old JSON-per-event encoding).
/// Layout (big-endian for integers, IEEE-754 for floats):
///
/// ```
/// 0  eventType:UInt8   1  buttonNumber:UInt8   2  clickCount:UInt8   3  flags:UInt8
/// 4  modifierFlags:UInt64
/// 12 x:Float32   16 y:Float32   20 deltaX:Float32   24 deltaY:Float32
/// 28 keyCode:UInt16   30 reserved:UInt16
/// ```
///
/// `x`/`y` are normalized 0..1 within the Display's content view (top-left origin).
public struct InputEventRecord: Sendable, Equatable {
    public var type: InputEventType
    public var buttonNumber: UInt8
    public var clickCount: UInt8
    public var modifierFlags: UInt64
    public var x: Float
    public var y: Float
    public var deltaX: Float
    public var deltaY: Float
    public var keyCode: UInt16

    public init(type: InputEventType, buttonNumber: UInt8 = 0, clickCount: UInt8 = 0,
                modifierFlags: UInt64 = 0, x: Float = 0, y: Float = 0,
                deltaX: Float = 0, deltaY: Float = 0, keyCode: UInt16 = 0) {
        self.type = type
        self.buttonNumber = buttonNumber
        self.clickCount = clickCount
        self.modifierFlags = modifierFlags
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
        d.append(0) // flags reserved
        ByteWriter.appendBE64(&d, modifierFlags)
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
        let modifierFlags = ByteReader.be64(data, b + 4)
        let x = ByteReader.beFloat(data, b + 12)
        let y = ByteReader.beFloat(data, b + 16)
        let deltaX = ByteReader.beFloat(data, b + 20)
        let deltaY = ByteReader.beFloat(data, b + 24)
        let keyCode = ByteReader.be16(data, b + 28)
        return InputEventRecord(type: type, buttonNumber: buttonNumber, clickCount: clickCount,
                                modifierFlags: modifierFlags, x: x, y: y,
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
