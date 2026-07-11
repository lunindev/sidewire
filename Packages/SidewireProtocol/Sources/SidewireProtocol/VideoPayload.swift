import Foundation

/// Helpers for the binary hot-path payloads: VIDEO, PING/PONG, LTR_ACK.

public enum VideoPayload {
    /// Size of the 4-byte video subheader that always precedes the Annex-B NAL data:
    /// `ltrToken:UInt16` + `reserved:UInt16`.
    public static let subheaderBytes = 4

    /// Build a VIDEO payload: 4-byte subheader + Annex-B NAL bytes.
    public static func encode(ltrToken: UInt16, nalData: Data) -> Data {
        var d = Data(capacity: subheaderBytes + nalData.count)
        ByteWriter.appendBE16(&d, ltrToken)
        ByteWriter.appendBE16(&d, 0) // reserved
        d.append(nalData)
        return d
    }

    /// Split a VIDEO payload into (ltrToken, NAL bytes). Returns nil if malformed.
    public static func decode(_ payload: Data) -> (ltrToken: UInt16, nalData: Data)? {
        guard payload.count >= subheaderBytes else { return nil }
        let b = payload.startIndex
        let token = ByteReader.be16(payload, b)
        let nal = Data(payload[(b + subheaderBytes)...])
        return (token, nal)
    }
}

public enum HeartbeatPayload {
    /// An 8-byte big-endian monotonic nanosecond timestamp for PING/PONG.
    public static func encode(_ monotonicNanos: UInt64) -> Data {
        var d = Data(capacity: 8)
        ByteWriter.appendBE64(&d, monotonicNanos)
        return d
    }
    public static func decode(_ payload: Data) -> UInt64? {
        guard payload.count >= 8 else { return nil }
        return ByteReader.be64(payload, payload.startIndex)
    }
}

public enum LTRAckPayload {
    /// `count:UInt16` followed by `count` × `UInt16` acknowledged LTR tokens.
    public static func encode(_ tokens: [UInt16]) -> Data {
        var d = Data(capacity: 2 + tokens.count * 2)
        ByteWriter.appendBE16(&d, UInt16(truncatingIfNeeded: tokens.count))
        for t in tokens { ByteWriter.appendBE16(&d, t) }
        return d
    }
    public static func decode(_ payload: Data) -> [UInt16] {
        guard payload.count >= 2 else { return [] }
        let b = payload.startIndex
        let count = Int(ByteReader.be16(payload, b))
        var tokens: [UInt16] = []
        var o = b + 2
        var i = 0
        while i < count, o + 2 <= payload.endIndex {
            tokens.append(ByteReader.be16(payload, o))
            o += 2; i += 1
        }
        return tokens
    }
}
