//! Reproduces every hex field of `protocol-vectors/pairing-vectors.json` byte-for-byte from each
//! vector's fixed inputs (`pin`, `clientSPKI`, `serverSPKI`, injected `scalarA`/`scalarB`). This is
//! the deterministic conformance target for Rust↔Swift CPace interop. The scalars are the
//! RNG-injection point; a live session samples fresh random scalars, so only the derivations are
//! reproducible here. If a field mismatches, the implementation is wrong — never the vector.

use std::path::PathBuf;

use serde::Deserialize;
use sidewire_crypto::cpace;

#[derive(Deserialize)]
struct PairingVector {
    name: String,
    pin: String,
    #[serde(rename = "clientSPKIHex")]
    client_spki_hex: String,
    #[serde(rename = "serverSPKIHex")]
    server_spki_hex: String,
    #[serde(rename = "channelBindingHex")]
    channel_binding_hex: String,
    #[serde(rename = "sidHex")]
    sid_hex: String,
    #[serde(rename = "scalarAHex")]
    scalar_a_hex: String,
    #[serde(rename = "scalarBHex")]
    scalar_b_hex: String,
    #[serde(rename = "generatorHex")]
    generator_hex: String,
    #[serde(rename = "shareAHex")]
    share_a_hex: String,
    #[serde(rename = "shareBHex")]
    share_b_hex: String,
    #[serde(rename = "kHex")]
    k_hex: String,
    #[serde(rename = "iskHex")]
    isk_hex: String,
    #[serde(rename = "macKeyHex")]
    mac_key_hex: String,
    #[serde(rename = "confirmAHex")]
    confirm_a_hex: String,
    #[serde(rename = "confirmBHex")]
    confirm_b_hex: String,
}

#[derive(Deserialize)]
struct PairingDoc {
    vectors: Vec<PairingVector>,
}

fn hx(s: &str) -> String {
    s.to_string()
}
fn h(s: &str) -> Vec<u8> {
    hex::decode(s).expect("valid hex")
}
fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn pairing_vectors_reproduce_all_fields() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../protocol-vectors/pairing-vectors.json");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let doc: PairingDoc = serde_json::from_slice(&bytes).expect("parse pairing-vectors.json");
    assert!(!doc.vectors.is_empty());

    for v in &doc.vectors {
        let client_spki = h(&v.client_spki_hex);
        let server_spki = h(&v.server_spki_hex);
        let scalar_a = h(&v.scalar_a_hex);
        let scalar_b = h(&v.scalar_b_hex);

        // CI = SHA256(clientSPKI ‖ serverSPKI); sid = SHA256(CI).
        let cb = cpace::channel_binding(&client_spki, &server_spki);
        assert_eq!(
            to_hex(&cb),
            hx(&v.channel_binding_hex),
            "{} channelBinding",
            v.name
        );
        let sid = cpace::sid(&cb);
        assert_eq!(to_hex(&sid), hx(&v.sid_hex), "{} sid", v.name);

        // g = calculate_generator(PIN, CI, sid).
        let g = cpace::calculate_generator(&v.pin, &cb, &sid);
        assert_eq!(to_hex(&g), hx(&v.generator_hex), "{} generator", v.name);

        // Ya = X25519(scalarA, g); Yb = X25519(scalarB, g).
        let share_a = cpace::scalar_mult(&scalar_a, &g).unwrap();
        let share_b = cpace::scalar_mult(&scalar_b, &g).unwrap();
        assert_eq!(to_hex(&share_a), hx(&v.share_a_hex), "{} shareA", v.name);
        assert_eq!(to_hex(&share_b), hx(&v.share_b_hex), "{} shareB", v.name);

        // K = X25519(scalarA, Yb) = X25519(scalarB, Ya); abort if all-zero.
        let k = cpace::scalar_mult_vfy(&scalar_a, &share_b).unwrap();
        let k_from_b = cpace::scalar_mult_vfy(&scalar_b, &share_a).unwrap();
        assert_eq!(k, k_from_b, "{} K must agree from both sides", v.name);
        assert_eq!(to_hex(&k), hx(&v.k_hex), "{} K", v.name);

        // ISK = SHA512(lv_cat(DSI_ISK, sid, K) ‖ lv_cat(Ya,"") ‖ lv_cat(Yb,"")), initiator first.
        let isk = cpace::derive_isk(&sid, &k, &share_a, b"", &share_b, b"");
        assert_eq!(to_hex(&isk), hx(&v.isk_hex), "{} ISK", v.name);

        // mac_key = SHA512("CPaceMac" ‖ sid ‖ ISK).
        let mac_key = cpace::derive_mac_key(&sid, &isk);
        assert_eq!(to_hex(&mac_key), hx(&v.mac_key_hex), "{} macKey", v.name);

        // confirmA/B = HMAC-SHA512(mac_key, lv_cat(share, "")).
        let confirm_a = cpace::confirmation_tag(&mac_key, &share_a, b"");
        let confirm_b = cpace::confirmation_tag(&mac_key, &share_b, b"");
        assert_eq!(
            to_hex(&confirm_a),
            hx(&v.confirm_a_hex),
            "{} confirmA",
            v.name
        );
        assert_eq!(
            to_hex(&confirm_b),
            hx(&v.confirm_b_hex),
            "{} confirmB",
            v.name
        );

        // The tags compare equal to themselves constant-time (and unequal cross-share).
        assert!(cpace::constant_time_equals(&confirm_a, &confirm_a));
        assert!(!cpace::constant_time_equals(&confirm_a, &confirm_b));
    }
}
