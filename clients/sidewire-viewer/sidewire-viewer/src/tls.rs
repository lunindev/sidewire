//! Certificate-based **TLS 1.3** with mutual auth via `rustls` on the **ring** provider.
//! Mirrors `TLS.swift`.
//!
//! There is no CA and no hostname to validate — trust is established at the app layer by the pinned
//! public key + the CPace PAKE. So the verifiers **accept any presented certificate** (no chain/CA
//! trust) but still perform real **proof-of-possession**: they verify the handshake signature via
//! `rustls::crypto::verify_tls13_signature` against the provider's algorithms. This is exactly the
//! Mac's Network.framework behavior (accept-any verify block, but TLS still proves the peer holds
//! the private key for the presented leaf).

use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    ClientConfig, DigitallySignedStruct, DistinguishedName, Error, ServerConfig, SignatureScheme,
};

use sidewire_crypto::{device_id_from_spki_hash, spki_hash_from_cert_der, Identity};

/// Errors building a TLS config or deriving peer identity.
#[derive(Debug, thiserror::Error)]
pub enum TlsError {
    #[error("rustls error: {0}")]
    Rustls(#[from] Error),
    #[error("the peer presented no leaf certificate")]
    NoPeerCert,
    #[error("the peer leaf public key is unreadable (unsupported cert?)")]
    UnreadablePeerKey,
}

/// The security context of an established TLS 1.3 connection, handed to the `Session` so it can run
/// (or skip) pairing and pin/verify the peer. Mirrors `TLSPeerInfo`.
#[derive(Debug, Clone)]
pub struct TlsPeerInfo {
    /// The peer's self-authenticating device id, derived from the presented leaf — NOT self-declared.
    pub peer_device_id: String,
    /// SHA-256 of the peer's DER SubjectPublicKeyInfo (32 bytes).
    pub peer_spki_hash: [u8; 32],
    /// SHA-256 of our own SPKI (32 bytes).
    pub own_spki_hash: [u8; 32],
    /// `SHA256(clientSPKI ‖ serverSPKI)` — the pairing channel binding (32 bytes).
    pub channel_binding: [u8; 32],
    /// True on the Display (listener/server) side, false on the Source (dialer/client) side.
    pub is_server: bool,
}

/// Derive [`TlsPeerInfo`] from a completed handshake's peer certificates. The channel-binding order
/// is always client (Source/dialer) first, server (Display/listener) second — both sides know their
/// role, so both derive the same value.
pub fn peer_info(
    peer_certs: Option<&[CertificateDer<'_>]>,
    own: &Identity,
    is_server: bool,
) -> Result<TlsPeerInfo, TlsError> {
    let leaf = peer_certs
        .and_then(|c| c.first())
        .ok_or(TlsError::NoPeerCert)?;
    // Fail closed if the leaf public key is unreadable (mirrors TCPTransport.publishSecurityContext:
    // falling through would skip pinning AND pairing entirely).
    let peer_spki = spki_hash_from_cert_der(leaf).ok_or(TlsError::UnreadablePeerKey)?;
    let peer_device_id = device_id_from_spki_hash(&peer_spki);
    let own_spki = own.spki_hash;
    let (client_spki, server_spki) = if is_server {
        (peer_spki, own_spki)
    } else {
        (own_spki, peer_spki)
    };
    let channel_binding = sidewire_crypto::cpace::channel_binding(&client_spki, &server_spki);
    Ok(TlsPeerInfo {
        peer_device_id,
        peer_spki_hash: peer_spki,
        own_spki_hash: own_spki,
        channel_binding,
        is_server,
    })
}

fn ring_provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn cert_and_key(identity: &Identity) -> (Vec<CertificateDer<'static>>, PrivateKeyDer<'static>) {
    let chain = vec![CertificateDer::from(identity.cert_der.clone())];
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.key_pkcs8_der.clone()));
    (chain, key)
}

/// Build the **server** (Display/listener) config: present our cert, require + verify a client cert
/// (mutual auth) but accept any chain/CA (pinning is the app layer's job). TLS 1.3 only.
pub fn server_config(identity: &Identity) -> Result<ServerConfig, TlsError> {
    let provider = ring_provider();
    let verifier = Arc::new(AnyClientCertVerifier {
        provider: provider.clone(),
    });
    let (chain, key) = cert_and_key(identity);
    let cfg = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(verifier)
        .with_single_cert(chain, key)?;
    Ok(cfg)
}

/// Build the **client** (Source/dialer) config: present our cert, accept any server cert (no
/// CA/hostname) but verify the handshake signature. TLS 1.3 only.
pub fn client_config(identity: &Identity) -> Result<ClientConfig, TlsError> {
    let provider = ring_provider();
    let verifier = Arc::new(AnyServerCertVerifier {
        provider: provider.clone(),
    });
    let (chain, key) = cert_and_key(identity);
    let cfg = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(chain, key)?;
    Ok(cfg)
}

/// A dummy server name for the client connection. The custom verifier ignores it (there is no
/// hostname to validate); pinning happens at the app layer on the derived `deviceId`.
pub fn dummy_server_name() -> ServerName<'static> {
    ServerName::try_from("sidewire").expect("static name is valid")
}

// ---------------------------------------------------------------------------
// Verifiers: accept any cert (no CA/chain), but keep the crypto proof-of-possession.
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct AnyClientCertVerifier {
    provider: Arc<CryptoProvider>,
}

impl ClientCertVerifier for AnyClientCertVerifier {
    fn client_auth_mandatory(&self) -> bool {
        true // the Display requests + requires a client cert (mutual auth)
    }

    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[] // no CA hints — we accept any self-signed leaf
    }

    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, Error> {
        // Accept any cert: skip only CA/chain trust; the app-layer pin + CPace are the real gate.
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        // Real proof-of-possession: the peer must have signed the handshake with the leaf's key.
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[derive(Debug)]
struct AnyServerCertVerifier {
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for AnyServerCertVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}
