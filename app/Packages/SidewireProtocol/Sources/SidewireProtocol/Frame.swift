import Foundation

/// A decoded wire frame: the raw type byte, flags, sequence, and payload bytes.
///
/// `rawType` is kept as `UInt8` (not `MessageType`) so that unknown/reserved
/// types survive parsing and can be skipped by the consumer's `switch` default.
public struct Frame: Sendable, Equatable {
    public let rawType: UInt8
    public let flags: UInt8
    public let seq: UInt32
    public let payload: Data

    public init(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) {
        self.rawType = rawType
        self.flags = flags
        self.seq = seq
        self.payload = payload
    }

    /// The known message type, or `nil` if the type is unknown/reserved.
    public var type: MessageType? { MessageType(rawValue: rawType) }
}

/// Encodes a single frame (12-byte header + payload) into `Data`, big-endian.
public enum FrameEncoder {
    public static func encode(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) -> Data {
        precondition(payload.count <= ProtocolConstants.maxFrameBytes)
        var out = Data(capacity: ProtocolConstants.frameHeaderBytes + payload.count)
        out.append(rawType)
        out.append(flags)
        out.append(0) // reserved hi
        out.append(0) // reserved lo
        appendBE(&out, UInt32(payload.count))
        appendBE(&out, seq)
        out.append(payload)
        return out
    }

    public static func encode(type: MessageType, flags: UInt8, seq: UInt32, payload: Data) -> Data {
        encode(rawType: type.rawValue, flags: flags, seq: seq, payload: payload)
    }

    private static func appendBE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

/// Incremental, allocation-safe frame parser. Feed it arbitrary byte chunks as
/// they arrive from the transport; it yields complete frames and buffers partials.
///
/// Unknown message types are parsed and returned like any other frame — the parser
/// never treats an unrecognized `type` as an error, which is what makes the protocol
/// forward-compatible (see docs/02-protocol.md).
public final class FrameParser {
    public enum ParseError: Error, Equatable {
        /// A frame declared a payload larger than `maxFrameBytes`; the stream is
        /// unrecoverable and the connection must be dropped.
        case frameTooLarge(UInt32)
    }

    private var buffer = Data()

    public init() {}

    /// Append incoming bytes and return all frames now fully available.
    /// Throws `frameTooLarge` on a corrupt/hostile length (caller drops the connection).
    public func append(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while let frame = try parseOne() {
            frames.append(frame)
        }
        return frames
    }

    /// Bytes buffered but not yet forming a complete frame (for diagnostics/tests).
    public var pendingByteCount: Int { buffer.count }

    private func parseOne() throws -> Frame? {
        let headerSize = ProtocolConstants.frameHeaderBytes
        guard buffer.count >= headerSize else { return nil }

        // Read header relative to the buffer's startIndex (Data may be sliced).
        let base = buffer.startIndex
        let rawType = buffer[base]
        let flags = buffer[base + 1]
        // bytes 2,3 reserved (ignored)
        let length = readBE32(buffer, base + 4)
        let seq = readBE32(buffer, base + 8)

        guard length <= UInt32(ProtocolConstants.maxFrameBytes) else {
            throw ParseError.frameTooLarge(length)
        }

        let total = headerSize + Int(length)
        guard buffer.count >= total else { return nil }

        let payloadStart = base + headerSize
        let payload = Data(buffer[payloadStart ..< (payloadStart + Int(length))])

        // Drop the consumed bytes. Re-base to keep indices sane.
        buffer.removeSubrange(base ..< (base + total))
        if buffer.isEmpty { buffer = Data() }

        return Frame(rawType: rawType, flags: flags, seq: seq, payload: payload)
    }

    private func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
