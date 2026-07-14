import Foundation

/// Helpers for the binary hot-path payloads: VIDEO, PING/PONG, LTR_ACK.

public enum VideoPayload {
    /// Size of the **12-byte** video subheader that always precedes the Annex-B NAL data:
    /// `ltrToken:UInt16` + `flags:UInt16` (reserved) + `pts:UInt64`.
    ///
    /// Layout (big-endian):
    /// ```
    /// off size field           notes
    /// 0   2    ltrToken:UInt16  reserved for future loss recovery; senders currently send 0
    /// 2   2    flags:UInt16     reserved; MUST be 0 on send, ignored on receive
    /// 4   8    pts:UInt64       capture presentation timestamp, NANOSECONDS on an arbitrary
    ///                           monotonic epoch (the source's capture clock). 0 = unspecified.
    /// 12  …    Annex-B NAL units (00 00 00 01 start codes)
    /// ```
    public static let subheaderBytes = 12

    /// Build a VIDEO payload: 12-byte subheader + Annex-B NAL bytes.
    /// `ptsNanos` is the capture timestamp in nanoseconds (monotonic epoch); pass 0 if unknown.
    public static func encode(ltrToken: UInt16, ptsNanos: UInt64, nalData: Data) -> Data {
        var d = Data(capacity: subheaderBytes + nalData.count)
        ByteWriter.appendBE16(&d, ltrToken)
        ByteWriter.appendBE16(&d, 0)          // flags (reserved)
        ByteWriter.appendBE64(&d, ptsNanos)   // capture PTS, nanoseconds
        d.append(nalData)
        return d
    }

    /// Split a VIDEO payload into (ltrToken, ptsNanos, NAL bytes). Returns nil if malformed.
    public static func decode(_ payload: Data) -> (ltrToken: UInt16, ptsNanos: UInt64, nalData: Data)? {
        guard payload.count >= subheaderBytes else { return nil }
        let b = payload.startIndex
        let token = ByteReader.be16(payload, b)
        // bytes 2..3 = flags (reserved, ignored)
        let pts = ByteReader.be64(payload, b + 4)
        let nal = Data(payload[(b + subheaderBytes)...])
        return (token, pts, nal)
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

public enum CursorPayload {
    /// An 8-byte payload: cursor `x` then `y`, each an IEEE-754 big-endian Float32, normalized
    /// 0..1 within the streamed display's bounds with a TOP-LEFT origin (matching the INPUT wire
    /// convention). Source→Display only; the Display warps its native cursor to this position.
    public static func encode(x: Float, y: Float) -> Data {
        var d = Data(capacity: 8)
        ByteWriter.appendBEFloat(&d, x)
        ByteWriter.appendBEFloat(&d, y)
        return d
    }
    public static func decode(_ payload: Data) -> (x: Float, y: Float)? {
        guard payload.count >= 8 else { return nil }
        let b = payload.startIndex
        return (ByteReader.beFloat(payload, b), ByteReader.beFloat(payload, b + 4))
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
