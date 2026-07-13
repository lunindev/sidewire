//! Input-send round-trip over **real TLS 1.3** on `127.0.0.1`: the Display's `run_streaming` drains a
//! channel of synthetic `InputEventRecord`s and sends them as `INPUT` frames (docs/02 § INPUT); the
//! Source peer receives, decodes, and we assert the 32-byte records round-trip **byte-identically**.
//! Both peers are pre-paired so CPace is skipped.

use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use sidewire_crypto::Identity;
use sidewire_proto::{
    hid_modifier, Capabilities, DisplayInfo, Hello, InputEventRecord, InputEventType, Role,
};
use sidewire_viewer::session::{
    HeartbeatConfig, PairingConfig, Session, SourceStreamPlan, SourceStreamResult,
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

/// The three synthetic events sent Display → Source: a pointer move with coords, a key with a HID
/// usage + modifier, and a scroll with pixel deltas.
fn sample_records() -> Vec<InputEventRecord> {
    let mut mouse = InputEventRecord::new(InputEventType::MouseMove);
    mouse.x = 0.25;
    mouse.y = 0.75;

    let mut key = InputEventRecord::new(InputEventType::KeyDown);
    key.key_code = 0x04; // 'a'
    key.modifiers = hid_modifier::LEFT_SHIFT;
    key.x = 0.5;
    key.y = 0.5;

    let mut scroll = InputEventRecord::new(InputEventType::ScrollWheel);
    scroll.delta_x = 3.0;
    scroll.delta_y = -12.0;

    vec![mouse, key, scroll]
}

#[test]
fn input_records_round_trip_display_to_source() {
    let display_id = Identity::generate().unwrap();
    let source_id = Identity::generate().unwrap();
    let display_trust = Arc::new(InMemoryTrustStore::new());
    let source_trust = Arc::new(InMemoryTrustStore::new());
    // Pre-pair both sides (skip CPace).
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

    let records = sample_records();

    // --- Display thread: pre-load the input channel, stream (send INPUT), stop on the Source's BYE.
    let d_records = records.clone();
    let display = std::thread::spawn(move || {
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

        // Queue the records, then drop the sender: run_streaming drains all three, sends them as
        // INPUT frames, and keeps streaming until the Source BYEs.
        let (tx, rx) = mpsc::channel();
        for r in &d_records {
            tx.send(*r).unwrap();
        }
        drop(tx);
        // No window here — the stop flag is never set; the Source's BYE ends the session.
        let stop = std::sync::atomic::AtomicBool::new(false);
        session.run_streaming(&rx, &stop, HeartbeatConfig::default(), |_nal, _kf, _pts| {})
    });

    // --- Source: connect, reach CONFIG, collect the 3 INPUT records, then BYE("user").
    let tcp = TcpStream::connect(addr).expect("connect");
    let (wire, tls_info) = Wire::connect(client_cfg, tcp, &source_id).expect("source TLS");
    let hello = Hello::new(
        Role::Source,
        source_id.device_id.clone(),
        "RustSource",
        "sess-s",
        caps(),
    );
    let pairing = PairingConfig::new("000000", source_trust, None);
    let src: SourceStreamResult = Session::new(Role::Source, hello, None, wire, tls_info, pairing)
        .run_source_stream(SourceStreamPlan {
            echo_pong: true,
            stop_after_inputs: Some(records.len()),
            max_duration: Duration::from_secs(3),
            ..Default::default()
        });

    let display_outcome = display.join().unwrap();

    // The Source received exactly the records the Display queued, byte-identically.
    assert_eq!(
        src.inputs, records,
        "INPUT records must round-trip byte-identically Display → Source"
    );
    // Clean shutdown driven by the Source's BYE("user").
    assert_eq!(display_outcome.close_reason.as_deref(), Some("user"));
}
