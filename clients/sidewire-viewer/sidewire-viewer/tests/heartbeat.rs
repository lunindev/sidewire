//! Heartbeat / watchdog liveness over **real TLS 1.3** on `127.0.0.1` (docs/02 § Heartbeat, docs/03
//! § watchdog), with **injected short intervals** so the tests don't wait real seconds. Both peers
//! are pre-paired (so CPace is skipped and the handshake is instant); the Display runs
//! `Session::run_streaming` (the product path) and the Source is driven by the test helper
//! `Session::run_source_stream`.

use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use sidewire_crypto::Identity;
use sidewire_proto::{Capabilities, DisplayInfo, Hello, Role};
use sidewire_viewer::session::{
    HeartbeatConfig, PairingConfig, Session, SessionOutcome, SourceStreamPlan, SourceStreamResult,
};
use sidewire_viewer::tls;
use sidewire_viewer::trust_store::{InMemoryTrustStore, TrustStoring, TrustedPeer};
use sidewire_viewer::wire::Wire;

fn caps() -> Capabilities {
    Capabilities::new(
        vec!["hevc".to_string()],
        3840,
        2160,
        60,
        false,
        false,
        false,
    )
}

fn display_info() -> DisplayInfo {
    DisplayInfo {
        width: 2560,
        height: 1600,
        scale_factor: 2.0,
        refresh_rate: 60.0,
        name: "panel".to_string(),
    }
}

struct Peers {
    display_id: Identity,
    source_id: Identity,
    display_trust: Arc<InMemoryTrustStore>,
    source_trust: Arc<InMemoryTrustStore>,
    listener: TcpListener,
    addr: std::net::SocketAddr,
    server_cfg: Arc<rustls::ServerConfig>,
    client_cfg: Arc<rustls::ClientConfig>,
}

/// Two peers that already trust each other (a prior pairing) — so every connection skips CPace and
/// goes straight to HELLO → CONFIG → streaming.
fn pre_paired() -> Peers {
    let display_id = Identity::generate().unwrap();
    let source_id = Identity::generate().unwrap();
    let display_trust = Arc::new(InMemoryTrustStore::new());
    let source_trust = Arc::new(InMemoryTrustStore::new());
    source_trust.pin(TrustedPeer::new(
        display_id.device_id.clone(),
        hex::encode(display_id.spki_hash),
        "D",
    ));
    display_trust.pin(TrustedPeer::new(
        source_id.device_id.clone(),
        hex::encode(source_id.spki_hash),
        "S",
    ));
    let server_cfg = Arc::new(tls::server_config(&display_id).unwrap());
    let client_cfg = Arc::new(tls::client_config(&source_id).unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    Peers {
        display_id,
        source_id,
        display_trust,
        source_trust,
        listener,
        addr,
        server_cfg,
        client_cfg,
    }
}

/// Spawn the Display: accept one connection and run `run_streaming` with `heartbeat` (no video, no
/// captured input). Returns its `SessionOutcome`.
fn spawn_display(p: &Peers, heartbeat: HeartbeatConfig) -> std::thread::JoinHandle<SessionOutcome> {
    let listener = p.listener.try_clone().unwrap();
    let server_cfg = p.server_cfg.clone();
    let display_id = p.display_id.clone();
    let display_trust = p.display_trust.clone();
    std::thread::spawn(move || {
        let (tcp, _) = listener.accept().expect("accept");
        let (wire, tls_info) = Wire::accept(server_cfg, tcp, &display_id).expect("display TLS");
        let hello = Hello::new(
            Role::Display,
            display_id.device_id.clone(),
            "RustDisplay",
            "sess-d",
            caps(),
        );
        let pairing = PairingConfig::new("000000", display_trust, None);
        let session = Session::new(
            Role::Display,
            hello,
            Some(display_info()),
            wire,
            tls_info,
            pairing,
        );
        // A live (never-disconnected) but empty input channel: no captured input in these tests.
        let (_tx, rx) = mpsc::channel();
        // No window in these tests, so the stop flag is never set (the peer/watchdog drives close).
        let stop = std::sync::atomic::AtomicBool::new(false);
        session.run_streaming(&rx, &stop, heartbeat, |_nal, _kf, _pts| {})
    })
}

/// Dial as the Source and run `plan` after CONFIG.
fn run_source(p: &Peers, plan: SourceStreamPlan) -> SourceStreamResult {
    let tcp = TcpStream::connect(p.addr).expect("connect");
    let (wire, tls_info) = Wire::connect(p.client_cfg.clone(), tcp, &p.source_id).expect("src TLS");
    let hello = Hello::new(
        Role::Source,
        p.source_id.device_id.clone(),
        "RustSource",
        "sess-s",
        caps(),
    );
    let pairing = PairingConfig::new("000000", p.source_trust.clone(), None);
    Session::new(Role::Source, hello, None, wire, tls_info, pairing).run_source_stream(plan)
}

// ---------------------------------------------------------------------------
// (a) A Source that goes silent after CONFIG → the Display closes "timeout".
// ---------------------------------------------------------------------------

#[test]
fn silent_source_trips_the_watchdog() {
    let p = pre_paired();
    // Injected short timing: PING every 20 ms, dead after 100 ms of inbound silence.
    let heartbeat = HeartbeatConfig {
        interval: Duration::from_millis(20),
        timeout: Duration::from_millis(100),
    };
    let display = spawn_display(&p, heartbeat);

    // The Source reaches CONFIG then stays silent (no PING, no PONG) — it only reads, so it will
    // notice the Display's BYE. It would otherwise sit for up to 5 s.
    let started = Instant::now();
    let src = run_source(
        &p,
        SourceStreamPlan {
            send_ping: false,
            echo_pong: false,
            max_duration: Duration::from_secs(5),
            ..Default::default()
        },
    );
    let display_outcome = display.join().unwrap();
    let elapsed = started.elapsed();

    // The Display declared the peer dead with the canonical timeout reason.
    assert_eq!(
        display_outcome.close_reason.as_deref(),
        Some("timeout"),
        "Display should close with 'timeout' on inbound silence"
    );
    // …and it did so promptly (a few× the 100 ms budget), not on the coarse 30 s socket timeout.
    assert!(
        elapsed < Duration::from_secs(2),
        "watchdog should fire near the injected timeout, took {elapsed:?}"
    );
    // The Source observed the Display's BYE (its own view of the reason is the received one).
    assert!(src.outcome.close_reason.is_some());
}

// ---------------------------------------------------------------------------
// (b) A Source that keeps PINGing → the Display stays alive and echoes PONG.
// ---------------------------------------------------------------------------

#[test]
fn active_source_keeps_the_link_alive() {
    let p = pre_paired();
    // Generous margin: 20 ms PINGs vs a 500 ms silence budget (25×), so scheduling jitter under
    // parallel test load (e.g. right after a full recompile) can't spuriously trip the watchdog.
    let heartbeat = HeartbeatConfig {
        interval: Duration::from_millis(20),
        timeout: Duration::from_millis(500),
    };
    let display = spawn_display(&p, heartbeat);

    // The Source pings every 20 ms (with a known 8-byte payload) and echoes the Display's pings, for
    // ~600 ms (2× the budget), then closes with BYE("user").
    const PING_PAYLOAD: [u8; 8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04];
    let src = run_source(
        &p,
        SourceStreamPlan {
            send_ping: true,
            ping_interval: Duration::from_millis(20),
            ping_payload: Some(PING_PAYLOAD),
            echo_pong: true,
            max_duration: Duration::from_millis(600),
            ..Default::default()
        },
    );
    let display_outcome = display.join().unwrap();

    // The Display did NOT self-close: it ended on the Source's clean BYE, not "timeout".
    assert_eq!(
        display_outcome.close_reason.as_deref(),
        Some("user"),
        "Display stayed alive for the whole window and closed on the Source's BYE"
    );
    // The Display echoed PONGs to the Source's PINGs (proves the heartbeat responder ran).
    assert!(
        src.pongs_received > 0,
        "the Source should have received PONGs echoing its PINGs"
    );
    // …and the PONG carried the EXACT 8-byte PING payload the Source sent (docs/02 § PING/PONG —
    // the responder must echo the ping bytes verbatim, not synthesize its own).
    assert_eq!(
        src.last_pong_payload.as_deref(),
        Some(&PING_PAYLOAD[..]),
        "the Display must echo the exact PING payload in its PONG"
    );
    // The Display also ORIGINATED its own PINGs on its cadence (stream_loop duty b) — this is what
    // keeps a real Mac Source's watchdog fed on a static screen, so assert it independently of PONG.
    assert!(
        src.pings_received > 0,
        "the Display should originate PINGs on its own heartbeat cadence"
    );
}
