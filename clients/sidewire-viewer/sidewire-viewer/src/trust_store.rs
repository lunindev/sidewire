//! The set of peers this device trusts, keyed by `deviceId`. Mirrors `TrustStore.swift`.
//! An in-memory implementation is provided (required for M1); a JSON-file-backed store is a
//! nice-to-have for later.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// A peer this device has paired with. Mirrors `TrustedPeer`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrustedPeer {
    /// The peer's self-authenticating device id (= first 16 bytes of `spki_hash`, hex).
    pub device_id: String,
    /// SHA-256 of the peer's DER SubjectPublicKeyInfo, lowercase hex — the pin.
    pub spki_hash: String,
    /// Human label (the peer's `deviceName` at pairing time). May be empty until the HELLO is seen.
    pub name: String,
    /// When this peer was first pinned (Unix epoch seconds).
    pub paired_at: f64,
}

impl TrustedPeer {
    pub fn new(
        device_id: impl Into<String>,
        spki_hash: impl Into<String>,
        name: impl Into<String>,
    ) -> Self {
        Self {
            device_id: device_id.into(),
            spki_hash: spki_hash.into(),
            name: name.into(),
            paired_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0),
        }
    }
}

/// The trust store interface. Implementations must be safe to call from any thread. Mirrors
/// `TrustStoring`.
pub trait TrustStoring: Send + Sync {
    /// All currently-pinned peers (for a "Paired Macs" list), sorted by `paired_at`.
    fn peers(&self) -> Vec<TrustedPeer>;
    /// The pin for a peer, or `None` if not paired.
    fn pinned(&self, device_id: &str) -> Option<TrustedPeer>;
    /// Pin (or update) a peer.
    fn pin(&self, peer: TrustedPeer);
    /// Revoke trust in a peer ("Forget this Mac"). The next connection re-pairs.
    fn forget(&self, device_id: &str);
    /// Convenience: is this peer currently trusted?
    fn is_paired(&self, device_id: &str) -> bool {
        self.pinned(device_id).is_some()
    }
}

/// A non-persistent trust store (tests, and a fallback if no persistent store is available).
/// Mirrors `InMemoryTrustStore`. Share it as `Arc<InMemoryTrustStore>` across threads.
#[derive(Default)]
pub struct InMemoryTrustStore {
    store: Mutex<HashMap<String, TrustedPeer>>,
}

impl InMemoryTrustStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl TrustStoring for InMemoryTrustStore {
    fn peers(&self) -> Vec<TrustedPeer> {
        let store = self.store.lock().unwrap();
        let mut v: Vec<TrustedPeer> = store.values().cloned().collect();
        v.sort_by(|a, b| a.paired_at.total_cmp(&b.paired_at));
        v
    }

    fn pinned(&self, device_id: &str) -> Option<TrustedPeer> {
        self.store.lock().unwrap().get(device_id).cloned()
    }

    fn pin(&self, peer: TrustedPeer) {
        self.store
            .lock()
            .unwrap()
            .insert(peer.device_id.clone(), peer);
    }

    fn forget(&self, device_id: &str) {
        self.store.lock().unwrap().remove(device_id);
    }
}
