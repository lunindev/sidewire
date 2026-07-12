//! Minimal CLI entrypoint for the Sidewire Rust Display (M1). Binds a TCP listener, generates a
//! device identity, prints the pairing PIN, accepts one connection, runs the Display session
//! through TLS 1.3 + CPace + HELLO to CONFIG, and logs the negotiated config.
//!
//! Decode + a window arrive in M2; this is intentionally small but real — it actually listens and
//! runs the Display state machine.

use std::net::TcpListener;
use std::sync::Arc;

use sidewire_crypto::Identity;
use sidewire_proto::{Capabilities, DisplayInfo, Hello, Role};
use sidewire_viewer::rate_limiter::PairingRateLimiter;
use sidewire_viewer::session::{PairingConfig, Session};
use sidewire_viewer::tls;
use sidewire_viewer::trust_store::{InMemoryTrustStore, TrustStoring};
use sidewire_viewer::wire::Wire;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port: u16 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(5005);

    // This device's long-lived identity + trust store + rate limiter.
    let identity = Identity::generate()?;
    let trust_store = Arc::new(InMemoryTrustStore::new());
    let rate_limiter = Arc::new(PairingRateLimiter::default_config());
    let pin = random_pin();

    let server_config = Arc::new(tls::server_config(&identity)?);

    let listener = TcpListener::bind(("0.0.0.0", port))?;
    let bound = listener.local_addr()?;
    println!("Sidewire Display (Rust) listening on {bound}");
    println!("  device id : {}", identity.device_id);
    println!("  pairing PIN: {pin}   (enter this on the Source Mac)");

    // M1: accept a single connection and drive it to CONFIG.
    let (tcp, peer_addr) = listener.accept()?;
    println!("accepted connection from {peer_addr}");

    let (wire, tls_info) = Wire::accept(server_config, tcp, &identity)?;
    println!(
        "TLS 1.3 established; peer device id = {} (paired: {})",
        tls_info.peer_device_id,
        trust_store.is_paired(&tls_info.peer_device_id)
    );

    let hello = Hello::new(
        Role::Display,
        identity.device_id.clone(),
        "Sidewire Rust Display",
        session_id(),
        display_capabilities(),
    );
    let display_info = DisplayInfo {
        width: 2560,
        height: 1600,
        scale_factor: 2.0,
        refresh_rate: 60.0,
        name: "Sidewire Rust Display".to_string(),
    };
    let pairing = PairingConfig::new(pin, trust_store.clone(), Some(rate_limiter));

    let session = Session::new(
        Role::Display,
        hello,
        Some(display_info),
        wire,
        tls_info,
        pairing,
    );
    let outcome = session.run();

    match outcome.config {
        Some(cfg) => {
            println!(
                "streaming negotiated: codec={} {}x{}@{} hiDPI={} ltr={} bitrate[{}..{}] start={}",
                cfg.codec,
                cfg.width,
                cfg.height,
                cfg.fps,
                cfg.hi_dpi,
                cfg.ltr,
                cfg.bitrate_min_bps,
                cfg.bitrate_max_bps,
                cfg.bitrate_start_bps,
            );
            println!("paired peers: {}", trust_store.peers().len());
        }
        None => {
            println!(
                "session closed before CONFIG: reason = {}",
                outcome.close_reason.as_deref().unwrap_or("<none>")
            );
        }
    }
    Ok(())
}

fn display_capabilities() -> Capabilities {
    Capabilities::new(
        vec!["hevc".to_string(), "h264".to_string()],
        3840,
        2160,
        60,
        false,
        false,
        false,
    )
}

/// A random 6-digit pairing PIN. M1 uses a fresh one per launch; rotation UX comes later.
fn random_pin() -> String {
    let r = sidewire_crypto::cpace::sample_scalar();
    let n = u32::from_le_bytes([r[0], r[1], r[2], r[3]]) % 1_000_000;
    format!("{n:06}")
}

/// A per-session opaque id (random hex). Not validated on the wire; informational.
fn session_id() -> String {
    let r = sidewire_crypto::cpace::sample_scalar();
    r[..8].iter().map(|b| format!("{b:02x}")).collect()
}
