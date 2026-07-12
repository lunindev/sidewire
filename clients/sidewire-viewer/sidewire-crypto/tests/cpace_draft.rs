//! Reproduces the **published** test vectors of `draft-irtf-cfrg-cpace-21` for the
//! CPACE-X25519-SHA512-ELLIGATOR2 ciphersuite, byte-for-byte — the same set the Swift
//! `CPaceVectorTests` checks. If any intermediate (generator, share, K, ISK, or a Field-arithmetic
//! reference) diverges from the draft, the crypto is wrong. Inputs/expected hex are copied verbatim
//! from `CPaceVectorTests.swift`.

use sha2::{Digest, Sha512};
use sidewire_crypto::cpace;
use sidewire_crypto::field::Field25519;

fn h(s: &str) -> Vec<u8> {
    hex::decode(s).expect("valid hex")
}

// Draft inputs (B.1).
fn prs() -> Vec<u8> {
    b"Password".to_vec()
}
fn ci() -> Vec<u8> {
    h("6f630b425f726573706f6e6465720b415f696e69746961746f72")
}
fn sid() -> Vec<u8> {
    h("7e4b4791d6a8ef019b936c79fb7f2c57")
}

// MARK: - String utilities (draft §A.1)

#[test]
fn prepend_len_and_lv_cat() {
    assert_eq!(cpace::prepend_len(&[]), vec![0x00]);
    assert_eq!(cpace::prepend_len(b"1234"), h("0431323334"));

    // 127-byte input → single-byte 0x7f prefix; 128 → two-byte LEB128 0x8001.
    let b127: Vec<u8> = (0u8..127).collect();
    assert_eq!(cpace::prepend_len(&b127)[..1], h("7f")[..]);
    let b128: Vec<u8> = (0u8..128).collect();
    assert_eq!(cpace::prepend_len(&b128)[..2], h("8001")[..]);

    assert_eq!(
        cpace::lv_cat(&[b"1234", b"5", b"", b"678"]),
        h("043132333401350003363738")
    );
}

// MARK: - Generator (draft §B.1.1)

#[test]
fn generator_string() {
    let gen = cpace::generator_string(&prs(), &ci(), &sid());
    assert_eq!(gen.len(), 172);
    let expected = format!(
        "0843506163653235350850617373776f72646d{}1a6f630b425f726573706f6e6465720b415f696e69746961746f72107e4b4791d6a8ef019b936c79fb7f2c57",
        "00".repeat(109)
    );
    assert_eq!(gen, h(&expected));
}

#[test]
fn calculate_generator_full_path() {
    // Full path: SHA-512(gen)[:32] → decodeUCoordinate → Elligator2.
    let gen = cpace::generator_string(&prs(), &ci(), &sid());
    let full = Sha512::digest(&gen);
    assert_eq!(
        full[..32],
        h("92806dc608984dbf4e4aae478c6ec453ae979cc01ecc1a2a7cf49f5cee56551b")[..]
    );
    let mut u = [0u8; 32];
    u.copy_from_slice(&full[..32]);
    u[31] &= 0x7F;
    let g = sidewire_crypto::elligator2::map(&u);
    assert_eq!(
        g.to_vec(),
        h("64e8099e3ea682cfdc5cb665c057ebb514d06bf23ebc9f743b51b82242327074")
    );

    // And the public entry point matches (PIN = "Password" here, CI/sid from the draft).
    let g2 = cpace::calculate_generator("Password", &ci(), &sid());
    assert_eq!(g, g2);
}

// MARK: - Elligator2 map vector (draft §B.1.1 intermediate)

#[test]
fn elligator2_map_vector() {
    let mut u = [0u8; 32];
    u.copy_from_slice(&h(
        "92806dc608984dbf4e4aae478c6ec453ae979cc01ecc1a2a7cf49f5cee56551b",
    ));
    // bit #255 already clear (last byte 0x1b), so decodeUCoordinate is a no-op here.
    assert_eq!(
        sidewire_crypto::elligator2::map(&u).to_vec(),
        h("64e8099e3ea682cfdc5cb665c057ebb514d06bf23ebc9f743b51b82242327074")
    );
}

// MARK: - Shares, K, ISK (draft §B.1.2–B.1.5)

#[test]
fn shares_k_and_isk() {
    let ya = h("21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080");
    let yb = h("848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a");
    let g = h("64e8099e3ea682cfdc5cb665c057ebb514d06bf23ebc9f743b51b82242327074");

    let ya_share = cpace::scalar_mult(&ya, &g).unwrap();
    let yb_share = cpace::scalar_mult(&yb, &g).unwrap();
    assert_eq!(
        ya_share.to_vec(),
        h("1b02dad6dbd29a07b6d28c9e04cb2f184f0734350e32bb7e62ff9dbcfdb63d15")
    );
    assert_eq!(
        yb_share.to_vec(),
        h("20cda5955f82c4931545bcbf40758ce1010d7db4db2a907013d79c7a8fcf957f")
    );

    let ka = cpace::scalar_mult_vfy(&ya, &yb_share).unwrap();
    let kb = cpace::scalar_mult_vfy(&yb, &ya_share).unwrap();
    assert_eq!(ka, kb);
    assert_eq!(
        ka.to_vec(),
        h("f97fdfcfff1c983ed6283856a401de3191ca919902b323c5f950c9703df7297a")
    );

    // ISK, initiator-responder ordering (transcript_ir).
    let isk = cpace::derive_isk(&sid(), &ka, &ya_share, b"ADa", &yb_share, b"ADb");
    assert_eq!(
        isk,
        h(
            "a051ee5ee2499d16da3f69f430218b8ea94a18a45b67f9e86495b382c33d14a5\
           c38cecc0cc834f960e39e0d1bf7d76b9ef5d54eecc5e0f386c97ad12da8c3d5f"
        )
    );
}

// MARK: - scalar_mult_vfy low-order points (draft §B.1.10)

#[test]
fn scalar_mult_vfy_rejects_low_order_points() {
    let s = h("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff");
    let abort_inputs = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    ];
    for u in abort_inputs {
        assert!(
            cpace::scalar_mult_vfy(&s, &h(u)).is_none(),
            "low-order point {u} must abort (K = I)"
        );
    }
    // A high-order point (bit #255 set, cleared per RFC 7748) must NOT abort.
    let high_order = "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    assert_eq!(
        cpace::scalar_mult_vfy(&s, &h(high_order)).map(|k| k.to_vec()),
        Some(h(
            "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"
        ))
    );
}

// MARK: - Field arithmetic self-consistency

#[test]
fn field_arithmetic_reference() {
    let a: [u8; 32] = (0u8..32).collect::<Vec<u8>>().try_into().unwrap();
    let b: [u8; 32] = (32u8..64).collect::<Vec<u8>>().try_into().unwrap();
    let fa = Field25519::from_le_bytes(&a);
    let fb = Field25519::from_le_bytes(&b);
    assert_eq!(
        fa.mul(&fb).to_le_bytes().to_vec(),
        h("1f8a85cd3caefc029ca2f163d41d1ba79cd62f83ab83e6aeb7dbf5e077951450")
    );
    assert_eq!(
        fa.inverted().to_le_bytes().to_vec(),
        h("4dcd88822d0589ded58c28d85290e85dcd88822d0589ded58c28d85290e85d73")
    );
    // a · a⁻¹ == 1
    assert_eq!(fa.mul(&fa.inverted()), Field25519::ONE);
}
