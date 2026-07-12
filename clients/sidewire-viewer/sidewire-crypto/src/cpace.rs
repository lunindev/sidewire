//! CPace — a balanced PAKE — run once, before HELLO, on a first-time pairing connection (docs/05).
//! A faithful port of `CPace.swift`. Every PIN guess costs one online interaction: a wrong PIN
//! yields an unrelated shared secret and the key-confirmation MAC simply fails.
//!
//! ## Ciphersuite: CPACE-X25519-SHA512-ELLIGATOR2 (`draft-irtf-cfrg-cpace-21`)
//! - Group `G_X25519`: `DSI = "CPace255"`, `DSI_ISK = "CPace255_ISK"`, `scalar_mult =
//!   scalar_mult_vfy = X25519` (RFC 7748, via `x25519-dalek` — clamps internally), identity
//!   `I = 0³²`.
//! - Hash `SHA-512`: `s_in_bytes = 128`. The one custom primitive is the Elligator2 map
//!   ([`crate::elligator2`] + [`crate::field`]).
//!
//! ## Sidewire bindings (what the Mac Source expects)
//! - `PRS` = `utf8(PIN)`; `CI` = the 32-byte TLS `channelBinding` = `SHA256(clientSPKI‖serverSPKI)`;
//!   `sid` = `SHA256(channelBinding)`; `ADa = ADb = ""` (deviceIds already bound through `CI`).
//! - Source is initiator (A), Display is responder (B). Transcript ordering is initiator-first.
//! - Key confirmation: `mac_key = SHA512("CPaceMac"‖sid‖ISK)`; each party sends `HMAC-SHA512(mac_key,
//!   lv_cat(ownShare, ownAD))` and verifies the peer's constant-time.
//!
//! Verified byte-for-byte against the draft's published X25519/SHA-512 vectors and
//! `protocol-vectors/pairing-vectors.json`.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256, Sha512};
use subtle::ConstantTimeEq;

type HmacSha512 = Hmac<Sha512>;

/// Domain separation identifier for the group.
pub const DSI: &[u8] = b"CPace255";
/// Domain separation identifier for the ISK derivation.
pub const DSI_ISK: &[u8] = b"CPace255_ISK";
/// SHA-512 input block size, in bytes (the zero-pad target in `generator_string`).
pub const S_IN_BYTES: usize = 128;
/// X25519 field/element size.
pub const ELEMENT_BYTES: usize = 32;
/// Prefix for the MAC-key derivation.
pub const MAC_PREFIX: &[u8] = b"CPaceMac";

// MARK: - Channel binding + sid

/// `SHA256(clientSPKI ‖ serverSPKI)` — always client (Source) first, server (Display) second.
/// The value CPace uses as its `CI`.
pub fn channel_binding(client_spki: &[u8], server_spki: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(client_spki);
    h.update(server_spki);
    h.finalize().into()
}

/// `sid = SHA256(channelBinding)` (32 bytes). Deterministic; both peers derive it identically.
pub fn sid(channel_binding: &[u8]) -> [u8; 32] {
    Sha256::digest(channel_binding).into()
}

// MARK: - String utilities (draft §A.1)

/// LEB128 length prefix followed by the data (`prepend_len`).
pub fn prepend_len(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut length = data.len();
    loop {
        if length < 128 {
            out.push(length as u8);
        } else {
            out.push(((length & 0x7F) + 0x80) as u8);
        }
        length >>= 7;
        if length == 0 {
            break;
        }
    }
    out.extend_from_slice(data);
    out
}

/// Length-prefixed concatenation (`lv_cat`).
pub fn lv_cat(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for p in parts {
        out.extend_from_slice(&prepend_len(p));
    }
    out
}

// MARK: - Generator (draft §8.1 / §8.2)

/// `generator_string(DSI, PRS, CI, sid, s_in_bytes)` with the zero padding that fills the first
/// hash block.
pub fn generator_string(prs: &[u8], ci: &[u8], sid: &[u8]) -> Vec<u8> {
    let zpad = S_IN_BYTES.saturating_sub(prepend_len(prs).len() + prepend_len(DSI).len() + 1);
    let zeros = vec![0u8; zpad];
    lv_cat(&[DSI, prs, &zeros, ci, sid])
}

/// `g = calculate_generator(H, PRS, CI, sid)`: hash the generator string, take the first 32 bytes,
/// apply `decodeUCoordinate` (clear bit #255), then Elligator2-map to a u-coordinate.
pub fn calculate_generator(pin: &str, ci: &[u8], sid: &[u8]) -> [u8; 32] {
    let gen = generator_string(pin.as_bytes(), ci, sid);
    let full = Sha512::digest(&gen);
    let mut u = [0u8; ELEMENT_BYTES];
    u.copy_from_slice(&full[..ELEMENT_BYTES]); // gen_str_hash[:field_size_bytes]
    u[31] &= 0x7F; // decodeUCoordinate(·, 255): clear bit #255
    crate::elligator2::map(&u)
}

// MARK: - Scalar sampling

/// A fresh CPace scalar: `sample_random_bytes(32)`. X25519 clamps internally, so no masking is
/// applied here (per the draft's `G_X25519.sample_scalar`). A live session samples a new one per
/// pairing; the vectors inject fixed values instead.
pub fn sample_scalar() -> [u8; 32] {
    let mut s = [0u8; ELEMENT_BYTES];
    getrandom::getrandom(&mut s).expect("system RNG unavailable");
    s
}

// MARK: - Scalar multiplication (X25519)

/// `X25519(scalar, u)` — our own share `Ya = scalar_mult(ya, g)`. Returns `None` only if a length
/// is wrong (an honest generator never yields the identity here).
pub fn scalar_mult(scalar: &[u8], u: &[u8]) -> Option<[u8; 32]> {
    x25519_op(scalar, u, false)
}

/// `scalar_mult_vfy(scalar, peerShare)` for the shared secret `K`. Returns `None` (→ abort) if the
/// result is the identity `I = 0³²` (the peer sent a low-order point), as the draft mandates
/// ("MUST abort if K = G.I").
pub fn scalar_mult_vfy(scalar: &[u8], peer_share: &[u8]) -> Option<[u8; 32]> {
    x25519_op(scalar, peer_share, true)
}

fn x25519_op(scalar: &[u8], u: &[u8], reject_identity: bool) -> Option<[u8; 32]> {
    if scalar.len() != ELEMENT_BYTES || u.len() != ELEMENT_BYTES {
        return None;
    }
    let mut s = [0u8; 32];
    s.copy_from_slice(scalar);
    let mut p = [0u8; 32];
    p.copy_from_slice(u);
    // x25519-dalek clamps the scalar internally (RFC 7748) and masks the u high bit — matching
    // swift-crypto's Curve25519 behavior. For a low-order peer point the result is all-zero.
    let out = x25519_dalek::x25519(s, p);
    if reject_identity && out.iter().all(|b| *b == 0) {
        return None;
    }
    Some(out)
}

// MARK: - ISK + key confirmation (draft §7.2 / §10.4)

/// `ISK = H(lv_cat(DSI_ISK, sid, K) ‖ transcript_ir(Ya,ADa,Yb,ADb))`, initiator (A) first.
#[allow(clippy::too_many_arguments)]
pub fn derive_isk(
    sid: &[u8],
    k: &[u8],
    initiator_share: &[u8],
    initiator_ad: &[u8],
    responder_share: &[u8],
    responder_ad: &[u8],
) -> Vec<u8> {
    let mut m = lv_cat(&[DSI_ISK, sid, k]);
    m.extend_from_slice(&lv_cat(&[initiator_share, initiator_ad]));
    m.extend_from_slice(&lv_cat(&[responder_share, responder_ad]));
    Sha512::digest(&m).to_vec()
}

/// `mac_key = H("CPaceMac" ‖ sid ‖ ISK)` (64 bytes).
pub fn derive_mac_key(sid: &[u8], isk: &[u8]) -> Vec<u8> {
    let mut h = Sha512::new();
    h.update(MAC_PREFIX);
    h.update(sid);
    h.update(isk);
    h.finalize().to_vec()
}

/// A party's confirmation tag `MAC(mac_key, lv_cat(ownShare, ownAD))` — HMAC-SHA512.
pub fn confirmation_tag(mac_key: &[u8], share: &[u8], ad: &[u8]) -> Vec<u8> {
    let msg = lv_cat(&[share, ad]);
    let mut mac = HmacSha512::new_from_slice(mac_key).expect("HMAC accepts any key length");
    mac.update(&msg);
    mac.finalize().into_bytes().to_vec()
}

/// Constant-time comparison of a received confirmation tag against the expected value.
pub fn constant_time_equals(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.ct_eq(b).into()
}
