//! End-to-end tests over **real TLS 1.3** on `127.0.0.1`: a Rust Source (CPace initiator) and a
//! Rust Display (CPace responder) talking through actual `rustls` connections. These exercise the
//! full pairing + HELLO state machine and the security-critical Tb-withhold ordering.
//!
//! The Rust client is always the Display in production; the Source peer here is a test helper (as
//! the spec allows) so the state machine can be driven without a live Mac.

use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use sidewire_crypto::Identity;
use sidewire_proto::{Capabilities, DisplayInfo, Hello, MessageType, Role};
use sidewire_viewer::rate_limiter::{ManualClock, PairingRateLimiter};
use sidewire_viewer::session::{PairingConfig, Session, SessionOutcome};
use sidewire_viewer::tls;
use sidewire_viewer::trust_store::{InMemoryTrustStore, TrustStoring, TrustedPeer};
use sidewire_viewer::wire::Wire;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn caps() -> Capabilities {
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

fn display_hello(id: &Identity) -> Hello {
    Hello::new(
        Role::Display,
        id.device_id.clone(),
        "RustDisplay",
        "sess-d",
        caps(),
    )
}

fn source_hello(id: &Identity) -> Hello {
    Hello::new(
        Role::Source,
        id.device_id.clone(),
        "RustSource",
        "sess-s",
        caps(),
    )
}

fn display_info() -> DisplayInfo {
    DisplayInfo {
        width: 2560,
        height: 1600,
        scale_factor: 2.0,
        refresh_rate: 60.0,
        name: "test panel".to_string(),
    }
}

fn hexstr(b: &[u8]) -> String {
    hex::encode(b)
}

/// Spawn a Display thread that accepts `n` connections, running a Display `Session` on each with the
/// (shared) trust store + rate limiter. Returns each connection's outcome, in order.
#[allow(clippy::too_many_arguments)]
fn spawn_display(
    n: usize,
    listener: TcpListener,
    server_cfg: Arc<rustls::ServerConfig>,
    id: Identity,
    trust: Arc<InMemoryTrustStore>,
    pin: String,
    rate_limiter: Option<Arc<PairingRateLimiter>>,
) -> JoinHandle<Vec<SessionOutcome>> {
    std::thread::spawn(move || {
        let mut outcomes = Vec::new();
        for _ in 0..n {
            let (tcp, _) = listener.accept().expect("accept");
            tcp.set_read_timeout(Some(Duration::from_secs(15))).ok();
            let (wire, tls_info) = match Wire::accept(server_cfg.clone(), tcp, &id) {
                Ok(v) => v,
                Err(e) => panic!("display TLS accept failed: {e}"),
            };
            let pairing = PairingConfig::new(pin.clone(), trust.clone(), rate_limiter.clone());
            let session = Session::new(
                Role::Display,
                display_hello(&id),
                Some(display_info()),
                wire,
                tls_info,
                pairing,
            );
            outcomes.push(session.run());
        }
        outcomes
    })
}

/// Dial the Display and run a Source `Session` to completion, returning its outcome.
fn run_source(
    addr: std::net::SocketAddr,
    client_cfg: Arc<rustls::ClientConfig>,
    id: &Identity,
    trust: Arc<InMemoryTrustStore>,
    pin: &str,
) -> SessionOutcome {
    let tcp = TcpStream::connect(addr).expect("tcp connect");
    tcp.set_read_timeout(Some(Duration::from_secs(15))).ok();
    let (wire, tls_info) = Wire::connect(client_cfg, tcp, id).expect("source TLS connect");
    let pairing = PairingConfig::new(pin.to_string(), trust, None);
    Session::new(
        Role::Source,
        source_hello(id),
        None,
        wire,
        tls_info,
        pairing,
    )
    .run()
}

struct Setup {
    display_id: Identity,
    source_id: Identity,
    display_trust: Arc<InMemoryTrustStore>,
    source_trust: Arc<InMemoryTrustStore>,
    listener: TcpListener,
    addr: std::net::SocketAddr,
    server_cfg: Arc<rustls::ServerConfig>,
    client_cfg: Arc<rustls::ClientConfig>,
}

fn setup() -> Setup {
    let display_id = Identity::generate().unwrap();
    let source_id = Identity::generate().unwrap();
    let server_cfg = Arc::new(tls::server_config(&display_id).unwrap());
    let client_cfg = Arc::new(tls::client_config(&source_id).unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    Setup {
        display_id,
        source_id,
        display_trust: Arc::new(InMemoryTrustStore::new()),
        source_trust: Arc::new(InMemoryTrustStore::new()),
        listener,
        addr,
        server_cfg,
        client_cfg,
    }
}

// ---------------------------------------------------------------------------
// 1. First-time pairing → CONFIG
// ---------------------------------------------------------------------------

#[test]
fn first_time_pairing_reaches_config() {
    let s = setup();
    let display_device = s.display_id.device_id.clone();
    let source_device = s.source_id.device_id.clone();
    let display_spki = s.display_id.spki_hash;
    let source_spki = s.source_id.spki_hash;

    let display = spawn_display(
        1,
        s.listener,
        s.server_cfg,
        s.display_id,
        s.display_trust.clone(),
        "123456".to_string(),
        None,
    );

    let source_outcome = run_source(
        s.addr,
        s.client_cfg,
        &s.source_id,
        s.source_trust.clone(),
        "123456",
    );
    let display_outcome = display.join().unwrap().remove(0);

    // Both sides reached CONFIG with the negotiated stream parameters.
    let scfg = source_outcome
        .config
        .as_ref()
        .expect("source reached CONFIG");
    assert_eq!(scfg.codec, "hevc");
    assert_eq!(scfg.width, 2560);
    assert_eq!(scfg.height, 1600);
    assert_eq!(scfg.fps, 60);
    let dcfg = display_outcome
        .config
        .as_ref()
        .expect("display reached CONFIG");
    assert_eq!(dcfg.codec, "hevc");
    assert_eq!(dcfg.width, 2560);
    assert_eq!(dcfg.height, 1600);

    // CPace completed and both sides pinned each other with matching SPKI hashes.
    let pinned_display = s
        .source_trust
        .pinned(&display_device)
        .expect("source pinned display");
    assert_eq!(pinned_display.spki_hash, hexstr(&display_spki));
    let pinned_source = s
        .display_trust
        .pinned(&source_device)
        .expect("display pinned source");
    assert_eq!(pinned_source.spki_hash, hexstr(&source_spki));

    // A CPace exchange really happened on this first-time pairing.
    assert!(source_outcome.sent_count(MessageType::PairMsg) > 0);
    assert!(source_outcome.sent_count(MessageType::PairConfirm) > 0);
    assert!(display_outcome.sent_count(MessageType::PairMsg) > 0);

    // Security-critical: the Display must NOT have sent its confirmation tag (Tb) before receiving
    // the Source's (Ta). Its first PAIR_CONFIRM sent must come after its first received.
    assert!(
        !display_outcome.sent_before_received(MessageType::PairConfirm),
        "Tb-withhold violated: the Display revealed its tag before verifying the Source's"
    );
    // And it did eventually send exactly one Tb.
    assert_eq!(display_outcome.sent_count(MessageType::PairConfirm), 1);
}

// ---------------------------------------------------------------------------
// 2. Wrong PIN → BYE("auth")
// ---------------------------------------------------------------------------

#[test]
fn wrong_pin_closes_with_auth() {
    let s = setup();
    let display_device = s.display_id.device_id.clone();
    let source_device = s.source_id.device_id.clone();
    let limiter = Arc::new(PairingRateLimiter::default_config());

    let display = spawn_display(
        1,
        s.listener,
        s.server_cfg,
        s.display_id,
        s.display_trust.clone(),
        "111111".to_string(),
        Some(limiter.clone()),
    );

    // Source uses a different PIN.
    let source_outcome = run_source(
        s.addr,
        s.client_cfg,
        &s.source_id,
        s.source_trust.clone(),
        "999999",
    );
    let display_outcome = display.join().unwrap().remove(0);

    assert_eq!(source_outcome.config, None, "must not reach streaming");
    assert_eq!(display_outcome.close_reason.as_deref(), Some("auth"));
    assert_eq!(source_outcome.close_reason.as_deref(), Some("auth"));

    // The rate limiter charged exactly one failure.
    assert_eq!(limiter.consecutive_failures(), 1);

    // No pinning on a failed proof.
    assert!(s.source_trust.pinned(&display_device).is_none());
    assert!(s.display_trust.pinned(&source_device).is_none());
}

// ---------------------------------------------------------------------------
// 3. Paired reconnect skips CPace
// ---------------------------------------------------------------------------

#[test]
fn paired_reconnect_skips_cpace() {
    let s = setup();
    // Both sides already trust each other (a prior pairing).
    s.source_trust.pin(TrustedPeer::new(
        s.display_id.device_id.clone(),
        hexstr(&s.display_id.spki_hash),
        "D",
    ));
    s.display_trust.pin(TrustedPeer::new(
        s.source_id.device_id.clone(),
        hexstr(&s.source_id.spki_hash),
        "S",
    ));

    let display = spawn_display(
        1,
        s.listener,
        s.server_cfg,
        s.display_id,
        s.display_trust.clone(),
        "123456".to_string(),
        None,
    );

    let source_outcome = run_source(
        s.addr,
        s.client_cfg,
        &s.source_id,
        s.source_trust.clone(),
        "123456",
    );
    let display_outcome = display.join().unwrap().remove(0);

    // Reached CONFIG...
    assert!(source_outcome.config.is_some(), "source reached CONFIG");
    assert!(display_outcome.config.is_some(), "display reached CONFIG");

    // ...and NO pairing messages crossed the wire in either direction.
    assert_eq!(source_outcome.sent_count(MessageType::PairMsg), 0);
    assert_eq!(source_outcome.recv_count(MessageType::PairMsg), 0);
    assert_eq!(source_outcome.sent_count(MessageType::PairConfirm), 0);
    assert_eq!(source_outcome.recv_count(MessageType::PairConfirm), 0);
    assert_eq!(display_outcome.sent_count(MessageType::PairMsg), 0);
    assert_eq!(display_outcome.sent_count(MessageType::PairConfirm), 0);

    // HELLO did flow (the handshake reached streaming).
    assert!(source_outcome.sent_count(MessageType::Hello) > 0);
    assert!(display_outcome.sent_count(MessageType::Hello) > 0);
}

// ---------------------------------------------------------------------------
// 4. Rate-limit lockout (injectable clock)
// ---------------------------------------------------------------------------

#[test]
fn rate_limit_locks_out_after_five_failures() {
    let s = setup();
    // A limiter on a manual clock so the lockout does not require sleeping the 60 s base window.
    let clock = Arc::new(ManualClock::new());
    let limiter = Arc::new(PairingRateLimiter::with_clock(
        5,
        Duration::from_secs(60),
        Duration::from_secs(900),
        clock.clone(),
    ));

    // The Display accepts six connections with the shared limiter + trust store.
    let display = spawn_display(
        6,
        s.listener,
        s.server_cfg,
        s.display_id,
        s.display_trust.clone(),
        "111111".to_string(),
        Some(limiter.clone()),
    );

    // Five consecutive wrong-PIN attempts, each with a FRESH source identity (so it is never pinned
    // and always runs CPace). Each must close with "auth".
    for i in 0..5 {
        let src = Identity::generate().unwrap();
        let client_cfg = Arc::new(tls::client_config(&src).unwrap());
        let outcome = run_source(
            s.addr,
            client_cfg,
            &src,
            Arc::new(InMemoryTrustStore::new()),
            "999999",
        );
        assert_eq!(
            outcome.close_reason.as_deref(),
            Some("auth"),
            "attempt {i} should fail with auth"
        );
    }

    // The limiter is now locked. The sixth attempt — even with the CORRECT PIN — is refused
    // immediately with BYE("rateLimited"), before CPace runs (no PAIR_MSG reply from the Display).
    let src = Identity::generate().unwrap();
    let client_cfg = Arc::new(tls::client_config(&src).unwrap());
    let sixth = run_source(
        s.addr,
        client_cfg,
        &src,
        Arc::new(InMemoryTrustStore::new()),
        "111111",
    );
    assert_eq!(sixth.close_reason.as_deref(), Some("rateLimited"));
    assert!(sixth.recv_count(MessageType::Bye) > 0);
    // The Display never replied with its share (CPace was not even run).
    assert_eq!(sixth.recv_count(MessageType::PairMsg), 0);

    display.join().unwrap();
}
