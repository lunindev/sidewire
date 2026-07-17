//! The set of peers this device trusts, keyed by `deviceId`. Mirrors `TrustStore.swift`.
//! An in-memory implementation (tests) and a JSON-file-backed one (the product path — pins survive
//! a restart, so a paired Source doesn't have to re-enter the PIN and doesn't see `keyChanged`).

use std::collections::HashMap;
use std::path::PathBuf;
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

/// A JSON-file-backed trust store: loads pins on open, rewrites the file on every pin/forget.
/// Mirrors the Swift Keychain store's durability so a paired Source is remembered across restarts.
/// All mutations are best-effort persisted — a write failure logs but never blocks pairing.
pub struct FileTrustStore {
    path: PathBuf,
    store: Mutex<HashMap<String, TrustedPeer>>,
}

impl FileTrustStore {
    /// Open (or start empty) the store at `path`. A missing or unparseable file yields an empty
    /// store — a corrupt file is not fatal; the user just re-pairs.
    pub fn open(path: PathBuf) -> Self {
        let store = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Vec<TrustedPeer>>(&bytes).ok())
            .map(|peers| {
                peers
                    .into_iter()
                    .map(|p| (p.device_id.clone(), p))
                    .collect()
            })
            .unwrap_or_default();
        Self {
            path,
            store: Mutex::new(store),
        }
    }

    fn save(&self, store: &HashMap<String, TrustedPeer>) {
        let mut peers: Vec<&TrustedPeer> = store.values().collect();
        peers.sort_by(|a, b| a.paired_at.total_cmp(&b.paired_at));
        let json = match serde_json::to_vec_pretty(&peers) {
            Ok(j) => j,
            Err(e) => {
                log::warn!("trust store: serialize failed: {e}");
                return;
            }
        };
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        // Atomic: write a sibling temp then rename, so a crash mid-write can't leave a truncated
        // file (which open() would silently treat as empty, dropping every pin).
        let tmp = self.path.with_extension("tmp");
        if let Err(e) = std::fs::write(&tmp, json) {
            log::warn!("trust store: write {:?} failed: {e}", tmp);
            return;
        }
        if let Err(e) = std::fs::rename(&tmp, &self.path) {
            log::warn!("trust store: rename into {:?} failed: {e}", self.path);
        }
    }
}

impl TrustStoring for FileTrustStore {
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
        let mut store = self.store.lock().unwrap();
        store.insert(peer.device_id.clone(), peer);
        self.save(&store);
    }

    fn forget(&self, device_id: &str) {
        let mut store = self.store.lock().unwrap();
        store.remove(device_id);
        self.save(&store);
    }
}

#[cfg(test)]
mod file_store_tests {
    use super::*;

    #[test]
    fn persists_and_reloads_pins() {
        let dir = std::env::temp_dir().join(format!("sidewire-trust-test-{}", std::process::id()));
        let path = dir.join("trust.json");
        let _ = std::fs::remove_file(&path);

        {
            let s = FileTrustStore::open(path.clone());
            s.pin(TrustedPeer::new("dev-a", "hashA", "Mac A"));
            s.pin(TrustedPeer::new("dev-b", "hashB", "Mac B"));
            assert!(s.is_paired("dev-a"));
        }
        // A fresh open reloads what was written.
        let s2 = FileTrustStore::open(path.clone());
        assert_eq!(s2.pinned("dev-a").unwrap().spki_hash, "hashA");
        assert_eq!(s2.peers().len(), 2);
        s2.forget("dev-a");
        assert!(!s2.is_paired("dev-a"));

        let s3 = FileTrustStore::open(path.clone());
        assert!(!s3.is_paired("dev-a"));
        assert!(s3.is_paired("dev-b"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
