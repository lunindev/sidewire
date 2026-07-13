//! mDNS / DNS-SD discovery (Phase 8 M4).
//!
//! The Rust client is always the **Display**, so its core discovery duty is to **advertise**
//! `_sidewire._tcp` at its listener port with a TXT record — exactly what the Swift Display does:
//!
//! * `TCPListener.swift` registers `NWListener.Service(name: <deviceName>, type: "_sidewire._tcp",
//!   txtRecord: {did, tb})` at the listener's port;
//! * `DisplayController.swift` builds that TXT as `{"did": deviceId}` plus optional `{"tb": <TB IP>}`.
//!
//! A Mac **Source** then *browses* `_sidewire._tcp` and dials us, reading the TXT keys **`did`** (our
//! self-authenticating device id, so it can enforce public-key pinning / `keyChanged`) and **`tb`**
//! (an optional Thunderbolt link-local IP) — see `Discovery.swift` (`DiscoveredPeer` + `txtValue`).
//!
//! We also expose a [`browse`]/[`discover`] helper for a `--discover` diagnostic and to exercise the
//! TXT-parsing path. Note that live multicast resolution is environment-dependent (it does not
//! resolve in the dev/CI box used here — a browse gets `SearchStarted` but never `ServiceResolved`),
//! so the unit tests below construct/parse a [`ServiceInfo`] **structurally** (no daemon, no
//! multicast); any live round-trip is gated behind `#[ignore]`.
//!
//! Constants mirror docs/02 § Constants and `ProtocolConstants.swift`: `BONJOUR_SERVICE_TYPE =
//! "_sidewire._tcp"`, TXT keys `did` / `tb`.

use std::collections::HashMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

use mdns_sd::{Receiver, ServiceDaemon, ServiceEvent, ServiceInfo};

pub use sidewire_proto::constants::BONJOUR_SERVICE_TYPE as SERVICE_TYPE;

/// The mDNS registration/browse domain — the bare service type (docs/02) qualified into the
/// `.local.` domain that DNS-SD requires. Kept in sync with [`SERVICE_TYPE`] by [`tests`].
pub const SERVICE_TYPE_DOMAIN: &str = "_sidewire._tcp.local.";

/// TXT key carrying the Display's self-authenticating device id (mirrors `Discovery.swift` "did").
pub const TXT_KEY_DID: &str = "did";
/// TXT key carrying the Display's optional Thunderbolt link-local IP (mirrors `Discovery.swift` "tb").
pub const TXT_KEY_TB: &str = "tb";

/// Errors advertising or browsing over mDNS.
#[derive(Debug, thiserror::Error)]
pub enum DiscoveryError {
    #[error("mDNS error: {0}")]
    Mdns(#[from] mdns_sd::Error),
}

/// A Sidewire Display discovered on the LAN. The Rust client *produces* these (via [`browse`]) only
/// for the `--discover` diagnostic; in production the Mac Source is the browser. Field-for-field the
/// portable subset of Swift's `DiscoveredPeer`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredPeer {
    /// The DNS-SD instance name (the advertised device name), e.g. `"Sidewire Rust Display"`.
    pub instance_name: String,
    /// The advertised host name (e.g. `"sidewire.local."`).
    pub host: String,
    /// The port the Display is listening on.
    pub port: u16,
    /// TXT `did` — the peer's device id, if advertised and non-empty (mirrors `txtValue`).
    pub device_id: Option<String>,
    /// TXT `tb` — the peer's Thunderbolt link-local IP, if advertised and non-empty.
    pub thunderbolt_ip: Option<String>,
    /// Resolved interface addresses (empty for a structurally-constructed, un-resolved service).
    pub addresses: Vec<IpAddr>,
}

/// Build the `ServiceInfo` the Display advertises — the **pure**, daemon-free construction path used
/// by both [`Advertiser::start`] and the unit tests. `addresses` is a comma-separated address list
/// (`""` = none; the live [`Advertiser`] passes `""` then [`ServiceInfo::enable_addr_auto`] so
/// mdns-sd fills in — and keeps updated — this host's real interface addresses).
///
/// TXT is `{did}` plus optional `{tb}` (only when non-empty), matching `DisplayController.swift`.
pub fn service_info(
    device_name: &str,
    device_id: &str,
    port: u16,
    thunderbolt_ip: Option<&str>,
    addresses: &str,
) -> Result<ServiceInfo, DiscoveryError> {
    let mut props: HashMap<String, String> = HashMap::new();
    props.insert(TXT_KEY_DID.to_string(), device_id.to_string());
    if let Some(tb) = thunderbolt_ip {
        if !tb.is_empty() {
            props.insert(TXT_KEY_TB.to_string(), tb.to_string());
        }
    }
    let host = host_name(device_name);
    let info = ServiceInfo::new(
        SERVICE_TYPE_DOMAIN,
        device_name,
        &host,
        addresses,
        port,
        props,
    )?;
    Ok(info)
}

/// Extract a [`DiscoveredPeer`] from a resolved [`ServiceInfo`]. **Pure** — no network — so the
/// TXT-parse logic (which mirrors `Discovery.swift`'s `txtValue`: a value is only taken when
/// present *and* non-empty) is unit-testable without multicast.
pub fn peer_from_service_info(info: &ServiceInfo) -> DiscoveredPeer {
    DiscoveredPeer {
        instance_name: instance_from_fullname(info.get_fullname()),
        host: info.get_hostname().to_string(),
        port: info.get_port(),
        device_id: txt_value(info, TXT_KEY_DID),
        thunderbolt_ip: txt_value(info, TXT_KEY_TB),
        addresses: info.get_addresses().iter().copied().collect(),
    }
}

/// Read a TXT value, returning `None` when the key is absent **or** empty — matches Swift's
/// `txtValue` (`!value.isEmpty`).
fn txt_value(info: &ServiceInfo, key: &str) -> Option<String> {
    info.get_property_val_str(key)
        .map(str::to_string)
        .filter(|v| !v.is_empty())
}

/// Recover the instance (device) name from a DNS-SD fullname `"<instance>._sidewire._tcp.local."`.
fn instance_from_fullname(fullname: &str) -> String {
    let suffix = format!(".{SERVICE_TYPE_DOMAIN}");
    fullname
        .strip_suffix(&suffix)
        .unwrap_or(fullname)
        .trim_end_matches('.')
        .to_string()
}

/// Derive a valid `.local.` mDNS host label from a device name (lowercased, non-alphanumerics → `-`).
/// The host name is cosmetic — DNS-SD resolution keys off the SRV/instance record — but mdns-sd
/// requires a plausible label, so keep it simple and safe.
fn host_name(device_name: &str) -> String {
    let mapped: String = device_name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = mapped.trim_matches('-');
    let label = if trimmed.is_empty() {
        "sidewire"
    } else {
        trimmed
    };
    format!("{label}.local.")
}

/// Advertises this Display's `_sidewire._tcp` service for the lifetime of the value; [`Drop`] (or
/// [`Advertiser::stop`]) unregisters it. Wraps an mdns-sd [`ServiceDaemon`] (which runs its own
/// background thread), so it can be created from anywhere.
pub struct Advertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

impl Advertiser {
    /// Register `_sidewire._tcp` with instance name `device_name`, TXT `did = device_id` (+ optional
    /// `tb`), at `port`. Addresses are auto-filled/kept-current from the host's interfaces.
    pub fn start(
        device_name: &str,
        device_id: &str,
        port: u16,
        thunderbolt_ip: Option<&str>,
    ) -> Result<Advertiser, DiscoveryError> {
        let daemon = ServiceDaemon::new()?;
        let info =
            service_info(device_name, device_id, port, thunderbolt_ip, "")?.enable_addr_auto();
        let fullname = info.get_fullname().to_string();
        daemon.register(info)?;
        Ok(Advertiser { daemon, fullname })
    }

    /// The registered DNS-SD fullname (`"<instance>._sidewire._tcp.local."`).
    pub fn fullname(&self) -> &str {
        &self.fullname
    }

    /// Explicitly unregister (also done on [`Drop`]).
    pub fn stop(&self) -> Result<(), DiscoveryError> {
        self.daemon.unregister(&self.fullname)?;
        Ok(())
    }
}

impl Drop for Advertiser {
    fn drop(&mut self) {
        // Best-effort: send the goodbye packet, then tear down the daemon thread.
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}

/// Browse `_sidewire._tcp` for up to `timeout`, returning the distinct Displays that resolved. Used
/// by the `--discover` diagnostic. **Live multicast is environment-dependent** (it does not resolve
/// on the dev/CI box here — see the module docs); on such a network this returns an empty list.
pub fn discover(timeout: Duration) -> Result<Vec<DiscoveredPeer>, DiscoveryError> {
    let daemon = ServiceDaemon::new()?;
    let receiver = daemon.browse(SERVICE_TYPE_DOMAIN)?;
    let peers = collect_peers(&receiver, timeout);
    let _ = daemon.shutdown();
    Ok(peers)
}

/// Lower-level browse: hand back the raw mdns-sd event channel so a caller can stream
/// [`ServiceEvent`]s (and turn `ServiceResolved` into a [`DiscoveredPeer`] via
/// [`peer_from_service_info`]). The returned [`ServiceDaemon`] must be kept alive for the browse to
/// continue; drop it (or call `shutdown`) to stop.
pub fn browse() -> Result<(ServiceDaemon, Receiver<ServiceEvent>), DiscoveryError> {
    let daemon = ServiceDaemon::new()?;
    let receiver = daemon.browse(SERVICE_TYPE_DOMAIN)?;
    Ok((daemon, receiver))
}

/// Drain a browse channel until `timeout`, collecting distinct resolved peers (deduped by instance
/// name, mirroring `Discovery.swift`'s name-dedupe across interfaces).
fn collect_peers(receiver: &Receiver<ServiceEvent>, timeout: Duration) -> Vec<DiscoveredPeer> {
    let deadline = Instant::now() + timeout;
    let mut peers: Vec<DiscoveredPeer> = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        match receiver.recv_timeout(remaining) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                let peer = peer_from_service_info(&info);
                if !peers.iter().any(|p| p.instance_name == peer.instance_name) {
                    peers.push(peer);
                }
            }
            // SearchStarted / ServiceFound / ServiceRemoved / etc. — not a resolved peer.
            Ok(_) => {}
            // Timed out (deadline reached) or the channel closed.
            Err(_) => break,
        }
    }
    peers
}

#[cfg(test)]
mod tests {
    use super::*;

    const DID: &str = "0011223344556677";
    const TB: &str = "169.254.10.20";

    /// The `.local.`-qualified domain must stay in lockstep with the bare service-type constant
    /// (docs/02 § Constants). Catches drift if either is edited.
    #[test]
    fn service_type_domain_matches_constant() {
        assert_eq!(SERVICE_TYPE, "_sidewire._tcp");
        assert_eq!(SERVICE_TYPE_DOMAIN, format!("{SERVICE_TYPE}.local."));
    }

    /// (a) The Advertiser's construction path yields the correct type / instance / port / TXT — all
    /// without a daemon or multicast.
    #[test]
    fn service_info_has_expected_type_instance_port_and_txt() {
        let info = service_info("Sidewire Rust Display", DID, 5005, Some(TB), "192.168.1.50")
            .expect("build service info");
        assert_eq!(info.get_type(), SERVICE_TYPE_DOMAIN);
        assert_eq!(
            instance_from_fullname(info.get_fullname()),
            "Sidewire Rust Display"
        );
        assert_eq!(info.get_port(), 5005);
        assert_eq!(info.get_property_val_str(TXT_KEY_DID), Some(DID));
        assert_eq!(info.get_property_val_str(TXT_KEY_TB), Some(TB));
    }

    /// (b1) `peer_from_service_info` recovers did + tb + port + instance from a constructed service.
    #[test]
    fn peer_from_service_info_recovers_did_and_tb() {
        let info = service_info("Panel-A", DID, 5005, Some(TB), "10.0.0.7").unwrap();
        let peer = peer_from_service_info(&info);
        assert_eq!(peer.instance_name, "Panel-A");
        assert_eq!(peer.port, 5005);
        assert_eq!(peer.device_id.as_deref(), Some(DID));
        assert_eq!(peer.thunderbolt_ip.as_deref(), Some(TB));
        assert!(peer.addresses.contains(&"10.0.0.7".parse().unwrap()));
    }

    /// (b2) A service without `tb` → `thunderbolt_ip = None`, but `did` is still recovered.
    #[test]
    fn peer_from_service_info_missing_tb_is_none() {
        let info = service_info("Panel-B", DID, 5005, None, "10.0.0.8").unwrap();
        let peer = peer_from_service_info(&info);
        assert_eq!(peer.device_id.as_deref(), Some(DID));
        assert_eq!(peer.thunderbolt_ip, None);
    }

    /// (b3) A service with no TXT at all → both `did` and `tb` are `None` (missing-key path), and an
    /// **empty** `did` value is likewise treated as absent (mirrors Swift's non-empty rule).
    #[test]
    fn peer_from_service_info_missing_or_empty_did_is_none() {
        let bare = ServiceInfo::new(
            SERVICE_TYPE_DOMAIN,
            "NoTxt",
            "notxt.local.",
            "10.0.0.9",
            5005,
            HashMap::<String, String>::new(),
        )
        .unwrap();
        let peer = peer_from_service_info(&bare);
        assert_eq!(peer.device_id, None);
        assert_eq!(peer.thunderbolt_ip, None);

        // Empty-string did behaves as absent.
        let empty_did = service_info("Empty", "", 5005, None, "10.0.0.10").unwrap();
        assert_eq!(peer_from_service_info(&empty_did).device_id, None);
    }

    /// The real product advertise path — `ServiceDaemon::new` + `register` + `fullname` + `Drop`
    /// (unregister/shutdown) — works and yields a well-formed fullname under the service type. This
    /// does NOT assert live resolution (multicast-blocked here), only that advertising itself
    /// succeeds; it is what the Display actually runs in listen mode.
    #[test]
    fn advertiser_registers_and_reports_fullname() {
        let adv = Advertiser::start("Sidewire Rust Display", DID, 5005, None)
            .expect("advertiser should register (daemon create + register)");
        assert!(
            adv.fullname().ends_with(SERVICE_TYPE_DOMAIN),
            "fullname {:?} should be under {SERVICE_TYPE_DOMAIN}",
            adv.fullname()
        );
        // Drop here unregisters + shuts the daemon down (best-effort) — must not panic.
    }

    /// (c) Live advertise → browse round-trip. Ignored: it depends on working multicast resolution,
    /// which the dev/CI box here does not provide (a browse gets `SearchStarted` but never
    /// `ServiceResolved`). Run on a real LAN: `cargo test -- --ignored live_advertise`.
    #[test]
    #[ignore = "requires a real multicast LAN; mDNS does not resolve on the dev/CI box (see task notes)"]
    fn live_advertise_then_discover_roundtrip() {
        let _adv =
            Advertiser::start("Sidewire Live Test", DID, 5005, Some(TB)).expect("start advertiser");
        std::thread::sleep(Duration::from_millis(500));
        let peers = discover(Duration::from_secs(3)).expect("discover");
        assert!(
            peers
                .iter()
                .any(|p| p.instance_name == "Sidewire Live Test"
                    && p.device_id.as_deref() == Some(DID)),
            "expected to discover the just-advertised service, got: {peers:?}"
        );
    }
}
