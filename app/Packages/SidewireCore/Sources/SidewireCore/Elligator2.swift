import Foundation

/// The Elligator2 map for Curve25519, per `draft-irtf-cfrg-cpace-21` §8.2 (which references the
/// `map_to_curve_elligator2` construction of RFC 9380). This maps a field element to a Montgomery
/// u-coordinate on Curve25519 (or its twist); CPace uses it to turn the hash of the PIN into the
/// secret generator `g`. Only the u-coordinate is needed, so the v-coordinate (and its sign) are
/// not computed.
///
/// Curve25519 parameters: A = 486662, B = 1, non-square Z = 2 (as the draft's `find_z_ell2`
/// yields for GF(2^255−19)). The reference algorithm (draft §A.2 `elligator2`) is:
///
///     v = −A / (1 + Z·r²)
///     ε = legendre(v³ + A·v² + B·v)          // +1 for a square, −1 otherwise
///     x = ε·v − (1 − ε)·(A/2)
///     return encodeUCoordinate(x)            // 32-byte little-endian
///
/// Verified byte-for-byte against the CPace draft's published `calculate_generator` test vector
/// for CPACE-X25519-SHA512-ELLIGATOR2 (see `Elligator2Tests`).
enum Elligator2 {
    /// Map a 32-byte little-endian field-element representation to a Curve25519 u-coordinate
    /// (32 bytes, little-endian). `decodeUCoordinate` semantics (RFC 7748) are applied to the
    /// input by `Field25519(littleEndian:)` — but the caller (`CPace.calculateGenerator`) has
    /// already masked bit #255, matching the draft.
    static func map(fieldBytes: [UInt8]) -> [UInt8] {
        let r = Field25519(littleEndian: fieldBytes)
        let A = Field25519.curveA

        // denom = 1 + Z·r²  (Z = 2)
        let r2 = r.squared()
        let denom = Field25519.one + r2 + r2 // 1 + 2·r²
        // v = −A / denom = (0 − A) · denom⁻¹
        let v = (Field25519.zero - A) * denom.inverted()

        // e = v³ + A·v² + v   (B = 1)
        let v2 = v.squared()
        let v3 = v2 * v
        let e = v3 + (A * v2) + v

        // ε = legendre(e): `one` for a nonzero square, `p−1` (−1) otherwise.
        let eps = e.legendre()
        let isSquare = eps == Field25519.one

        // x = v   if square, else  x = −v − A  (== ε·v − (1−ε)·(A/2), evaluated branch-free below).
        let xSquare = v
        let xNonSquare = (Field25519.zero - v) - A
        let x = Field25519.select(xNonSquare, xSquare, isSquare)
        return x.littleEndianBytes()
    }
}
