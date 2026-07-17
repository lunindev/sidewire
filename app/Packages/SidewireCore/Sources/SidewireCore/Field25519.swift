import Foundation

/// Arithmetic in the prime field GF(2^255 − 19), the base field of Curve25519.
///
/// This is the *one* custom cryptographic primitive Sidewire needs for CPace: the Elligator2
/// map-to-curve (see `Elligator2.swift`) operates on field elements, and swift-crypto exposes no
/// field arithmetic. Everything else in the CPace flow (X25519, SHA-512, HMAC) is swift-crypto.
///
/// Representation: four little-endian 64-bit limbs, `l[0]` = bits 0…63. Every public operation
/// returns a **canonical** value in `[0, p)`. The arithmetic is written *branch-free on secret data*
/// (conditional subtract/select via masks, a fixed-exponent ladder for inv/Legendre) to minimize
/// PIN-dependent timing. NOTE: this is a best-effort mitigation, not a hard guarantee — Swift/LLVM
/// may still lower a `cond ? a : b` to a branch, and `==` short-circuits. The residual leak (one
/// Legendre bit in the Elligator2 map) runs *locally* between receiving the channel binding and
/// sending our share, so it is not remotely measurable by an on-path attacker; a fully CT
/// implementation would need verified primitives we don't have in pure Swift.
///
/// Correctness is pinned by test vectors: `Elligator2Tests` reproduces the CPace draft's published
/// `calculate_generator` output byte-for-byte, which exercises mul/sqr/inv/pow/add/sub end to end.
/// Not performance-critical: it runs once per pairing.
struct Field25519: Equatable {
    /// Little-endian limbs; value = l[0] + l[1]·2^64 + l[2]·2^128 + l[3]·2^192.
    private var l: (UInt64, UInt64, UInt64, UInt64)

    /// p = 2^255 − 19, little-endian limbs.
    private static let pLimbs: (UInt64, UInt64, UInt64, UInt64) =
        (0xFFFF_FFFF_FFFF_FFED, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF)

    static let zero = Field25519(l: (0, 0, 0, 0))
    static let one = Field25519(l: (1, 0, 0, 0))
    /// The curve parameter A = 486662.
    static let curveA = Field25519(l: (486662, 0, 0, 0))

    private init(l: (UInt64, UInt64, UInt64, UInt64)) { self.l = l }

    // Canonical values only ⇒ limb-wise equality is exact. (Tuple stored property blocks
    // Equatable synthesis, so this is explicit.)
    static func == (x: Field25519, y: Field25519) -> Bool {
        x.l.0 == y.l.0 && x.l.1 == y.l.1 && x.l.2 == y.l.2 && x.l.3 == y.l.3
    }

    private func arr() -> [UInt64] { [l.0, l.1, l.2, l.3] }
    private init(_ a: [UInt64]) { l = (a[0], a[1], a[2], a[3]) }

    // MARK: - Encoding

    /// Decode 32 little-endian bytes as a field element, reduced mod p. (Any 256-bit input is
    /// accepted; the value is reduced into `[0, p)`.)
    init(littleEndian bytes: [UInt8]) {
        precondition(bytes.count == 32)
        var a = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var v: UInt64 = 0
            for j in 0..<8 { v |= UInt64(bytes[i * 8 + j]) << (8 * j) }
            a[i] = v
        }
        // Input may be in [p, 2^256); two conditional subtractions land it in [0, p).
        a = Field25519.condSubP(Field25519.condSubP(a))
        self.init(a)
    }

    /// Canonical 32-byte little-endian encoding (value < p).
    func littleEndianBytes() -> [UInt8] {
        let a = arr()
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<4 {
            for j in 0..<8 { out[i * 8 + j] = UInt8((a[i] >> (8 * j)) & 0xFF) }
        }
        return out
    }

    // MARK: - Add / sub

    static func + (x: Field25519, y: Field25519) -> Field25519 {
        let a = x.arr(), b = y.arr()
        var r = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, c1) = a[i].addingReportingOverflow(b[i])
            let (s2, c2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
        }
        // Both inputs < p ⇒ sum < 2p < 2^256 (no 5th-limb carry); one conditional subtract suffices.
        return Field25519(condSubP(r))
    }

    static func - (x: Field25519, y: Field25519) -> Field25519 {
        let a = x.arr(), b = y.arr()
        var r = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, b1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            r[i] = d2
            borrow = (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
        }
        // If it underflowed (a < b), add p back (constant-time via mask).
        let mask = UInt64(0) &- borrow // all-ones when borrow==1
        let p = pArr()
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, c1) = r[i].addingReportingOverflow(p[i] & mask)
            let (s2, c2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
        }
        return Field25519(r)
    }

    // MARK: - Multiply / square

    static func * (x: Field25519, y: Field25519) -> Field25519 {
        Field25519(reduce(mul256(x.arr(), y.arr())))
    }

    func squared() -> Field25519 { self * self }

    // MARK: - Inversion / exponentiation

    /// Multiplicative inverse: self^(p−2). (self must be nonzero; 0 maps to 0.)
    func inverted() -> Field25519 { pow(Field25519.expPMinus2) }

    /// Legendre symbol as a field element: self^((p−1)/2) — returns `one` for a nonzero square,
    /// `p−1` (i.e. −1) for a non-square, `zero` for zero.
    func legendre() -> Field25519 { pow(Field25519.expPMinus1Over2) }

    /// self^exponent, exponent as a big-endian byte array. Square-and-multiply, MSB first.
    /// The exponent is a fixed public constant, so branching on its bits is not a timing leak.
    private func pow(_ exponent: [UInt8]) -> Field25519 {
        var result = Field25519.one
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = result.squared()
                if (byte >> bit) & 1 == 1 { result = result * self }
            }
        }
        return result
    }

    /// p − 2 = 2^255 − 21, big-endian.
    private static let expPMinus2: [UInt8] = {
        var b = [UInt8](repeating: 0xFF, count: 32)
        b[0] = 0x7F; b[31] = 0xEB
        return b
    }()

    /// (p − 1) / 2 = 2^254 − 10, big-endian.
    private static let expPMinus1Over2: [UInt8] = {
        var b = [UInt8](repeating: 0xFF, count: 32)
        b[0] = 0x3F; b[31] = 0xF6
        return b
    }()

    // MARK: - Reduction helpers

    private static func pArr() -> [UInt64] { [pLimbs.0, pLimbs.1, pLimbs.2, pLimbs.3] }

    /// Schoolbook 256×256 → 512-bit product (8 limbs, little-endian).
    private static func mul256(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var t = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
                let (s1, c1) = t[i + j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                t[i + j] = s2
                carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            // Propagate the final row carry into the higher limbs.
            var k = i + 4
            while carry != 0 {
                let (s, c) = t[k].addingReportingOverflow(carry)
                t[k] = s
                carry = c ? 1 : 0
                k += 1
            }
        }
        return t
    }

    /// Reduce a 512-bit value (8 limbs) mod p, returning canonical 4 limbs in [0, p).
    /// Uses 2^256 ≡ 38 (mod p): fold the high half, then fold the small residual carry.
    private static func reduce(_ t: [UInt64]) -> [UInt64] {
        let lo = Array(t[0..<4])
        let hi = Array(t[4..<8])
        // 38·hi → 5 limbs.
        var m = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hh, ll) = hi[i].multipliedFullWidth(by: 38)
            let (s, c) = ll.addingReportingOverflow(carry)
            m[i] = s
            carry = hh &+ (c ? 1 : 0)
        }
        m[4] = carry
        // r = lo + 38·hi (m[4] stays tiny).
        carry = 0
        for i in 0..<4 {
            let (s1, c1) = m[i].addingReportingOverflow(lo[i])
            let (s2, c2) = s1.addingReportingOverflow(carry)
            m[i] = s2
            carry = (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
        }
        m[4] = m[4] &+ carry
        // Fold the top limb: value ≡ m[0..3] + 38·m[4] (mod p).
        var r = Array(m[0..<4])
        var extra = 38 &* m[4]
        carry = extra
        for i in 0..<4 {
            let (s, c) = r[i].addingReportingOverflow(carry)
            r[i] = s
            carry = c ? 1 : 0
        }
        // A carry out of bit 256 folds back as another 38.
        extra = 38 &* carry
        carry = extra
        for i in 0..<4 {
            let (s, c) = r[i].addingReportingOverflow(carry)
            r[i] = s
            carry = c ? 1 : 0
        }
        // r < 2^256 = 2p + 38 ⇒ at most two conditional subtractions land it in [0, p).
        return condSubP(condSubP(r))
    }

    /// Subtract p if `a` ≥ p, in constant time. `a` is 4 limbs.
    private static func condSubP(_ a: [UInt64]) -> [UInt64] {
        let p = pArr()
        var diff = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, b1) = a[i].subtractingReportingOverflow(p[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            diff[i] = d2
            borrow = (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
        }
        // borrow==0 ⇒ a ≥ p ⇒ take diff; borrow==1 ⇒ a < p ⇒ keep a.
        let takeDiff = UInt64(0) &- (borrow ^ 1) // all-ones when borrow==0
        var out = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 { out[i] = (diff[i] & takeDiff) | (a[i] & ~takeDiff) }
        return out
    }

    // MARK: - Constant-time select

    /// Returns `b` if `choose` is true, else `a` — without a secret-dependent branch.
    static func select(_ a: Field25519, _ b: Field25519, _ choose: Bool) -> Field25519 {
        let mask = UInt64(0) &- (choose ? 1 : 0)
        let av = a.arr(), bv = b.arr()
        var out = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 { out[i] = (bv[i] & mask) | (av[i] & ~mask) }
        return Field25519(out)
    }
}
