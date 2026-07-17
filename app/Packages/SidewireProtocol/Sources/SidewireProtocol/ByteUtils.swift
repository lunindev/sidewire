import Foundation

/// Big-endian append helpers.
enum ByteWriter {
    static func appendBE16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
    }
    static func appendBE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
    }
    static func appendBE64(_ d: inout Data, _ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            d.append(UInt8((v >> UInt64(shift)) & 0xFF))
        }
    }
    static func appendBEFloat(_ d: inout Data, _ v: Float) {
        appendBE32(&d, v.bitPattern)
    }
}

/// Big-endian read helpers. `offset` is an absolute index into `data`.
enum ByteReader {
    static func be16(_ d: Data, _ o: Int) -> UInt16 {
        (UInt16(d[o]) << 8) | UInt16(d[o + 1])
    }
    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
    }
    static func be64(_ d: Data, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(d[o + i]) }
        return v
    }
    static func beFloat(_ d: Data, _ o: Int) -> Float {
        Float(bitPattern: be32(d, o))
    }
}
