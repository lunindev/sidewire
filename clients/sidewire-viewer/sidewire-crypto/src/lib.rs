//! Sidewire pairing crypto — CPACE-X25519-SHA512-ELLIGATOR2, P-256 device identity, SPKI/deviceId.
//!
//! A faithful port of the crypto in the Swift `SidewireCore` package. The byte-exact conformance
//! targets are `protocol-vectors/pairing-vectors.json` and the published `draft-irtf-cfrg-cpace-21`
//! X25519/SHA-512 test vectors; the normative spec is `docs/05-security-and-pairing.md`.
//!
//! One crypto backend: `ring` (via rustls/rcgen), `x25519-dalek`, `sha2`, `hmac`, `subtle`. The
//! only hand-rolled primitive is the Elligator2 map (and its underlying [`field`] arithmetic),
//! because `curve25519-dalek`'s Elligator is not public.

pub mod cpace;
pub mod elligator2;
pub mod field;
pub mod identity;

pub use field::Field25519;
pub use identity::{device_id_from_spki_hash, spki_hash_from_cert_der, Identity, IdentityError};
