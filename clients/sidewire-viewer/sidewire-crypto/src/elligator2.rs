//! The Elligator2 map for Curve25519, per `draft-irtf-cfrg-cpace-21` §8.2 (RFC 9380's
//! `map_to_curve_elligator2`). Maps a field element to a Montgomery u-coordinate on Curve25519;
//! CPace uses it to turn the hash of the PIN into the secret generator `g`. Only the u-coordinate
//! is needed, so the v-coordinate (and its sign) are not computed.
//!
//! A faithful port of `Elligator2.swift`. curve25519-dalek's Elligator is not public, so this is
//! hand-rolled and verified byte-for-byte against the draft's published `calculate_generator`
//! vector (`64e8099e…327074`). Curve25519 parameters: A = 486662, B = 1, non-square Z = 2.
//!
//! Reference algorithm (draft §A.2 `elligator2`):
//! ```text
//! v = −A / (1 + Z·r²)
//! ε = legendre(v³ + A·v² + B·v)          // +1 for a square, −1 otherwise
//! x = ε·v − (1 − ε)·(A/2)                 // == v (square) or −v−A (non-square)
//! return encodeUCoordinate(x)             // 32-byte little-endian
//! ```

use crate::field::Field25519;

/// Map a 32-byte little-endian field-element representation to a Curve25519 u-coordinate (32
/// bytes, little-endian). The caller (`CPace::calculate_generator`) has already masked bit #255,
/// matching the draft's `decodeUCoordinate`.
pub fn map(field_bytes: &[u8; 32]) -> [u8; 32] {
    let r = Field25519::from_le_bytes(field_bytes);
    let a = Field25519::CURVE_A;

    // denom = 1 + Z·r²  (Z = 2)  ==  1 + r² + r²
    let r2 = r.squared();
    let denom = Field25519::ONE.add(&r2).add(&r2);
    // v = −A / denom = (0 − A) · denom⁻¹
    let v = Field25519::ZERO.sub(&a).mul(&denom.inverted());

    // e = v³ + A·v² + v   (B = 1)
    let v2 = v.squared();
    let v3 = v2.mul(&v);
    let e = v3.add(&a.mul(&v2)).add(&v);

    // ε = legendre(e): `ONE` for a nonzero square, `p−1` (−1) otherwise.
    let eps = e.legendre();
    let is_square = eps == Field25519::ONE;

    // x = v if square, else x = −v − A.
    let x_square = v;
    let x_non_square = Field25519::ZERO.sub(&v).sub(&a);
    let x = Field25519::select(&x_non_square, &x_square, is_square);
    x.to_le_bytes()
}
