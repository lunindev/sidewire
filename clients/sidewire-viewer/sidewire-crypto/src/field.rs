//! Arithmetic in the prime field GF(2^255 − 19), the base field of Curve25519.
//!
//! A faithful port of `Field25519.swift`. This is the one custom field primitive Sidewire needs
//! for CPace's Elligator2 map-to-curve; everything else (X25519, SHA-512, HMAC) comes from
//! vetted crates. Representation: four little-endian 64-bit limbs, `l[0]` = bits 0…63. Every public
//! operation returns a **canonical** value in `[0, p)`.
//!
//! The arithmetic mirrors the Swift branch-free style (conditional subtract/select via masks, a
//! fixed-exponent ladder for inv/Legendre) to minimize PIN-dependent timing. As in Swift this is a
//! best-effort mitigation, not a hard guarantee, and the residual Legendre leak in the Elligator2
//! map runs *locally* (never remotely measurable). Correctness is pinned by the CPace draft's
//! published `calculate_generator` vector, which exercises mul/sqr/inv/pow end to end.

/// A canonical field element in `[0, p)`, stored as four little-endian 64-bit limbs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Field25519 {
    l: [u64; 4],
}

/// p = 2^255 − 19, little-endian limbs.
const P: [u64; 4] = [
    0xFFFF_FFFF_FFFF_FFED,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_FFFF_FFFF,
    0x7FFF_FFFF_FFFF_FFFF,
];

impl Field25519 {
    pub const ZERO: Field25519 = Field25519 { l: [0, 0, 0, 0] };
    pub const ONE: Field25519 = Field25519 { l: [1, 0, 0, 0] };
    /// The curve parameter A = 486662.
    pub const CURVE_A: Field25519 = Field25519 {
        l: [486662, 0, 0, 0],
    };

    // MARK: - Encoding

    /// Decode 32 little-endian bytes as a field element, reduced mod p. Any 256-bit input is
    /// accepted (`decodeUCoordinate` semantics): two conditional subtractions land it in `[0, p)`.
    pub fn from_le_bytes(bytes: &[u8; 32]) -> Self {
        let mut a = [0u64; 4];
        for (i, limb) in a.iter_mut().enumerate() {
            let mut v: u64 = 0;
            for j in 0..8 {
                v |= (bytes[i * 8 + j] as u64) << (8 * j);
            }
            *limb = v;
        }
        // Input may be in [p, 2^256); two conditional subtractions land it in [0, p).
        let a = cond_sub_p(cond_sub_p(a));
        Field25519 { l: a }
    }

    /// Canonical 32-byte little-endian encoding (value < p).
    pub fn to_le_bytes(&self) -> [u8; 32] {
        let mut out = [0u8; 32];
        for i in 0..4 {
            for j in 0..8 {
                out[i * 8 + j] = ((self.l[i] >> (8 * j)) & 0xFF) as u8;
            }
        }
        out
    }

    // MARK: - Add / sub

    pub fn add(&self, other: &Field25519) -> Field25519 {
        let (a, b) = (self.l, other.l);
        let mut r = [0u64; 4];
        let mut carry: u64 = 0;
        for i in 0..4 {
            let (s1, c1) = a[i].overflowing_add(b[i]);
            let (s2, c2) = s1.overflowing_add(carry);
            r[i] = s2;
            carry = (c1 as u64) + (c2 as u64);
        }
        // Both inputs < p ⇒ sum < 2p < 2^256; one conditional subtract suffices.
        Field25519 { l: cond_sub_p(r) }
    }

    pub fn sub(&self, other: &Field25519) -> Field25519 {
        let (a, b) = (self.l, other.l);
        let mut r = [0u64; 4];
        let mut borrow: u64 = 0;
        for i in 0..4 {
            let (d1, b1) = a[i].overflowing_sub(b[i]);
            let (d2, b2) = d1.overflowing_sub(borrow);
            r[i] = d2;
            borrow = (b1 as u64) + (b2 as u64);
        }
        // If it underflowed (a < b), add p back (constant-time via mask).
        let mask = 0u64.wrapping_sub(borrow); // all-ones when borrow == 1
        let mut carry: u64 = 0;
        for i in 0..4 {
            let (s1, c1) = r[i].overflowing_add(P[i] & mask);
            let (s2, c2) = s1.overflowing_add(carry);
            r[i] = s2;
            carry = (c1 as u64) + (c2 as u64);
        }
        Field25519 { l: r }
    }

    // MARK: - Multiply / square

    pub fn mul(&self, other: &Field25519) -> Field25519 {
        Field25519 {
            l: reduce(mul256(self.l, other.l)),
        }
    }

    pub fn squared(&self) -> Field25519 {
        self.mul(self)
    }

    // MARK: - Inversion / exponentiation

    /// Multiplicative inverse: self^(p−2). (self must be nonzero; 0 maps to 0.)
    pub fn inverted(&self) -> Field25519 {
        // p − 2 = 2^255 − 21, big-endian.
        let mut exp = [0xFFu8; 32];
        exp[0] = 0x7F;
        exp[31] = 0xEB;
        self.pow(&exp)
    }

    /// Legendre symbol as a field element: self^((p−1)/2) — `ONE` for a nonzero square, `p−1`
    /// (i.e. −1) for a non-square, `ZERO` for zero.
    pub fn legendre(&self) -> Field25519 {
        // (p − 1) / 2 = 2^254 − 10, big-endian.
        let mut exp = [0xFFu8; 32];
        exp[0] = 0x3F;
        exp[31] = 0xF6;
        self.pow(&exp)
    }

    /// self^exponent, exponent as a big-endian byte array. Square-and-multiply, MSB first. The
    /// exponent is a fixed public constant, so branching on its bits is not a timing leak.
    fn pow(&self, exponent: &[u8; 32]) -> Field25519 {
        let mut result = Field25519::ONE;
        for byte in exponent {
            for bit in (0..8).rev() {
                result = result.squared();
                if (byte >> bit) & 1 == 1 {
                    result = result.mul(self);
                }
            }
        }
        result
    }

    // MARK: - Constant-time select

    /// Returns `b` if `choose` is true, else `a` — without a secret-dependent branch.
    pub fn select(a: &Field25519, b: &Field25519, choose: bool) -> Field25519 {
        let mask = 0u64.wrapping_sub(choose as u64);
        let mut out = [0u64; 4];
        for (i, o) in out.iter_mut().enumerate() {
            *o = (b.l[i] & mask) | (a.l[i] & !mask);
        }
        Field25519 { l: out }
    }
}

// MARK: - Reduction helpers (free functions)

/// Schoolbook 256×256 → 512-bit product (8 limbs, little-endian).
fn mul256(a: [u64; 4], b: [u64; 4]) -> [u64; 8] {
    let mut t = [0u64; 8];
    for i in 0..4 {
        let mut carry: u64 = 0;
        for j in 0..4 {
            let prod = (a[i] as u128) * (b[j] as u128);
            let lo = prod as u64;
            let hi = (prod >> 64) as u64;
            let (s1, c1) = t[i + j].overflowing_add(lo);
            let (s2, c2) = s1.overflowing_add(carry);
            t[i + j] = s2;
            carry = hi.wrapping_add(c1 as u64).wrapping_add(c2 as u64);
        }
        // Propagate the final row carry into the higher limbs.
        let mut k = i + 4;
        while carry != 0 {
            let (s, c) = t[k].overflowing_add(carry);
            t[k] = s;
            carry = c as u64;
            k += 1;
        }
    }
    t
}

/// Reduce a 512-bit value (8 limbs) mod p, returning canonical 4 limbs in [0, p).
/// Uses 2^256 ≡ 38 (mod p): fold the high half, then fold the small residual carry.
fn reduce(t: [u64; 8]) -> [u64; 4] {
    let lo = [t[0], t[1], t[2], t[3]];
    let hi = [t[4], t[5], t[6], t[7]];
    // 38·hi → 5 limbs.
    let mut m = [0u64; 5];
    let mut carry: u64 = 0;
    for i in 0..4 {
        let prod = (hi[i] as u128) * 38u128;
        let ll = prod as u64;
        let hh = (prod >> 64) as u64;
        let (s, c) = ll.overflowing_add(carry);
        m[i] = s;
        carry = hh.wrapping_add(c as u64);
    }
    m[4] = carry;
    // r = lo + 38·hi (m[4] stays tiny).
    carry = 0;
    for i in 0..4 {
        let (s1, c1) = m[i].overflowing_add(lo[i]);
        let (s2, c2) = s1.overflowing_add(carry);
        m[i] = s2;
        carry = (c1 as u64) + (c2 as u64);
    }
    m[4] = m[4].wrapping_add(carry);
    // Fold the top limb: value ≡ m[0..3] + 38·m[4] (mod p).
    let mut r = [m[0], m[1], m[2], m[3]];
    carry = 38u64.wrapping_mul(m[4]);
    for limb in r.iter_mut() {
        let (s, c) = limb.overflowing_add(carry);
        *limb = s;
        carry = c as u64;
    }
    // A carry out of bit 256 folds back as another 38.
    carry = 38u64.wrapping_mul(carry);
    for limb in r.iter_mut() {
        let (s, c) = limb.overflowing_add(carry);
        *limb = s;
        carry = c as u64;
    }
    // r < 2^256 = 2p + 38 ⇒ at most two conditional subtractions land it in [0, p).
    cond_sub_p(cond_sub_p(r))
}

/// Subtract p if `a` ≥ p, in constant time. `a` is 4 limbs.
fn cond_sub_p(a: [u64; 4]) -> [u64; 4] {
    let mut diff = [0u64; 4];
    let mut borrow: u64 = 0;
    for i in 0..4 {
        let (d1, b1) = a[i].overflowing_sub(P[i]);
        let (d2, b2) = d1.overflowing_sub(borrow);
        diff[i] = d2;
        borrow = (b1 as u64) + (b2 as u64);
    }
    // borrow == 0 ⇒ a ≥ p ⇒ take diff; borrow == 1 ⇒ a < p ⇒ keep a.
    let take_diff = 0u64.wrapping_sub(borrow ^ 1); // all-ones when borrow == 0
    let mut out = [0u64; 4];
    for i in 0..4 {
        out[i] = (diff[i] & take_diff) | (a[i] & !take_diff);
    }
    out
}
