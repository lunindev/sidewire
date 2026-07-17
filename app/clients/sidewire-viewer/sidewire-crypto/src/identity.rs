//! This device's long-lived cryptographic identity for certificate-based TLS 1.3 (docs/05).
//! A P-256 key pair + a minimal self-signed X.509 certificate, plus the pinning helpers.
//! Mirrors `LocalIdentity.swift`.
//!
//! - Curve **NIST P-256** (secp256r1); signature **ECDSA-with-SHA256** (rcgen `PKCS_ECDSA_P256_SHA256`).
//! - The certificate is an opaque key carrier: self-signed, `CN=Sidewire`, no CA/hostname to
//!   validate (trust is the pinned key + the CPace PAKE).
//! - `spki_hash` = **SHA-256 over the DER `SubjectPublicKeyInfo`** (RFC 7469 "SPKI Fingerprint").
//!   For P-256 the SPKI is the standard 91-byte `SEQUENCE { AlgorithmIdentifier(ecPublicKey,
//!   prime256v1), BIT STRING(0x04‖X‖Y) }` that OpenSSL `i2d_PUBKEY` and swift-crypto
//!   `derRepresentation` both produce — so the value is byte-identical across implementations.
//! - `device_id` = the first **16 bytes** of `spki_hash`, lowercase hex (32 chars). Self-
//!   authenticating: a peer cannot claim a `device_id` without holding the matching private key.

use rcgen::{
    CertificateParams, DistinguishedName, DnType, IsCa, KeyPair, KeyUsagePurpose,
    PKCS_ECDSA_P256_SHA256,
};
use sha2::{Digest, Sha256};
use x509_parser::certificate::X509Certificate;
use x509_parser::prelude::FromDer;

/// Errors constructing or persisting a device identity.
#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("certificate generation failed: {0}")]
    Rcgen(#[from] rcgen::Error),
    #[error("could not parse a PEM identity from disk")]
    PemParse,
}

/// A device identity: the DER/PEM cert + key, the SPKI fingerprint, and the derived device id.
#[derive(Clone)]
pub struct Identity {
    /// The leaf certificate, DER-encoded.
    pub cert_der: Vec<u8>,
    /// The private key, PKCS#8 DER-encoded.
    pub key_pkcs8_der: Vec<u8>,
    /// The leaf certificate, PEM-encoded (for on-disk persistence).
    pub cert_pem: String,
    /// The private key, PEM-encoded (PKCS#8).
    pub key_pem: String,
    /// The DER `SubjectPublicKeyInfo` (the 91-byte P-256 SPKI).
    pub spki_der: Vec<u8>,
    /// SHA-256 over `spki_der` (32 bytes) — the pinned fingerprint.
    pub spki_hash: [u8; 32],
    /// First 16 bytes of `spki_hash` as lowercase hex (32 chars). Advertised in HELLO.
    pub device_id: String,
}

impl Identity {
    /// Generate a fresh P-256 self-signed identity.
    pub fn generate() -> Result<Self, IdentityError> {
        let key_pair = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)?;
        let mut params = CertificateParams::new(Vec::<String>::new())?;
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, "Sidewire");
        params.distinguished_name = dn;
        // Cosmetic extensions matching docs/05 (BasicConstraints CA:FALSE, KeyUsage
        // digitalSignature). Only the public key matters to a peer.
        params.is_ca = IsCa::ExplicitNoCa;
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];

        let cert = params.self_signed(&key_pair)?;
        Ok(Self::from_parts(
            cert.der().to_vec(),
            key_pair.serialize_der(),
            cert.pem(),
            key_pair.serialize_pem(),
            key_pair.public_key_der(),
        ))
    }

    /// Reconstruct an identity from persisted PEM (cert + PKCS#8 key). The SPKI/device-id are
    /// recomputed from the certificate so a loaded identity is identical to a freshly generated one.
    pub fn from_pem(cert_pem: &str, key_pem: &str) -> Result<Self, IdentityError> {
        let key_pair = KeyPair::from_pem(key_pem).map_err(|_| IdentityError::PemParse)?;
        let cert_der = pem_to_der(cert_pem).ok_or(IdentityError::PemParse)?;
        Ok(Self::from_parts(
            cert_der,
            key_pair.serialize_der(),
            cert_pem.to_string(),
            key_pem.to_string(),
            key_pair.public_key_der(),
        ))
    }

    fn from_parts(
        cert_der: Vec<u8>,
        key_pkcs8_der: Vec<u8>,
        cert_pem: String,
        key_pem: String,
        spki_der: Vec<u8>,
    ) -> Self {
        let spki_hash: [u8; 32] = Sha256::digest(&spki_der).into();
        let device_id = device_id_from_spki_hash(&spki_hash);
        Self {
            cert_der,
            key_pkcs8_der,
            cert_pem,
            key_pem,
            spki_der,
            spki_hash,
            device_id,
        }
    }
}

/// SHA-256 SPKI fingerprint of a leaf certificate presented by a peer during TLS. Extracts the
/// DER `SubjectPublicKeyInfo` (`x509-parser`'s `subject_pki.raw` is exactly that) and hashes it —
/// the same computation as our own `spki_hash`, so both sides agree byte-for-byte.
pub fn spki_hash_from_cert_der(der: &[u8]) -> Option<[u8; 32]> {
    let (_, cert) = X509Certificate::from_der(der).ok()?;
    let spki_raw = cert.tbs_certificate.subject_pki.raw;
    Some(Sha256::digest(spki_raw).into())
}

/// Derive the stable, self-authenticating device id from an SPKI hash: first 16 bytes, lowercase hex.
pub fn device_id_from_spki_hash(hash: &[u8]) -> String {
    hash[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// Extract the DER bytes from a single-block PEM string.
fn pem_to_der(pem_str: &str) -> Option<Vec<u8>> {
    pem::parse(pem_str).ok().map(|p| p.into_contents())
}
