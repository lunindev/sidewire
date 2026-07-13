//! Sidewire Rust Display client (Phase 8, M2). Three entry paths:
//!
//! * `--file <clip.h264|.h265>` — decode a local Annex-B clip and render it to a window on a loop.
//!   The manual visual smoke test of the whole decode→render pipeline; needs no Mac.
//! * *(default)* listen — the real Display: bind a TLS 1.3 listener, print the pairing PIN, accept a
//!   connection, pair (CPace), reach CONFIG, then stream: receive VIDEO → decode → render to a
//!   window, with a periodic latency/stat log. (End-to-end needs a live Mac Source; wired up here.)
//! * `--handshake-only [port]` — the M1 behavior, preserved: accept one connection, drive it to
//!   CONFIG, log the negotiated config, exit. No window.
//!
//! The winit event loop runs on the **main thread** (macOS requirement); the network/session/decode
//! runs on a worker thread that posts decoded frames to the window (see [`window`]).

use std::net::TcpListener;
use std::sync::Arc;
use std::time::{Duration, Instant};

use sidewire_crypto::Identity;
use sidewire_media::{detect_codec, split_access_units, Codec, Decoder};
use sidewire_proto::{Capabilities, DisplayInfo, Hello, Role};
use sidewire_viewer::rate_limiter::PairingRateLimiter;
use sidewire_viewer::session::{PairingConfig, Session};
use sidewire_viewer::stats::{FrameStats, LatencyTracker};
use sidewire_viewer::tls;
use sidewire_viewer::trust_store::{InMemoryTrustStore, TrustStoring};
use sidewire_viewer::window::{self, FrameProducer};
use sidewire_viewer::wire::Wire;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();

    if let Some(pos) = args.iter().position(|a| a == "--file") {
        let path = args
            .get(pos + 1)
            .ok_or("--file requires a path to a .h264/.h265 Annex-B clip")?;
        return run_file_mode(path);
    }

    let handshake_only = args.iter().any(|a| a == "--handshake-only");
    let port: u16 = args
        .iter()
        .skip(1)
        .find(|a| !a.starts_with("--"))
        .and_then(|s| s.parse().ok())
        .unwrap_or(5005);

    if handshake_only {
        run_handshake_only(port)
    } else {
        run_listen_mode(port)
    }
}

// ---------------------------------------------------------------------------
// --file: decode a local clip and render it on a loop
// ---------------------------------------------------------------------------

fn run_file_mode(path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let data = std::fs::read(path)?;
    let codec = codec_for_file(path, &data).ok_or("could not determine codec for the clip")?;
    let aus = split_access_units(&data, codec);
    if aus.is_empty() {
        return Err("no access units found in clip".into());
    }
    println!("Sidewire Display (Rust) — file mode");
    println!("  clip   : {path}");
    println!("  codec  : {codec:?}");
    println!("  frames : {} access units (looping ~10 fps)", aus.len());
    println!("  close the window to exit.");

    window::run(
        format!("Sidewire — {path}"),
        move |producer: FrameProducer| {
            let mut decoder = match Decoder::new(codec) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("decoder init failed: {e}");
                    return;
                }
            };
            let mut pts: u64 = 0;
            'outer: loop {
                for au in &aus {
                    match decoder.decode_access_unit(&au.data, au.keyframe, pts) {
                        Ok(frames) => {
                            for f in frames {
                                if !producer.post(f) {
                                    break 'outer; // window closed
                                }
                            }
                        }
                        Err(e) => eprintln!("decode error: {e}"),
                    }
                    pts += 100_000_000; // 100 ms → ~10 fps pacing
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        },
    )?;
    Ok(())
}

/// Determine a clip's codec from its extension, falling back to sniffing the bitstream.
fn codec_for_file(path: &str, data: &[u8]) -> Option<Codec> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".h264") || lower.ends_with(".avc") || lower.ends_with(".264") {
        Some(Codec::H264)
    } else if lower.ends_with(".h265") || lower.ends_with(".hevc") || lower.ends_with(".265") {
        Some(Codec::Hevc)
    } else {
        detect_codec(data)
    }
}

// ---------------------------------------------------------------------------
// default: listen, pair, stream VIDEO → decode → render
// ---------------------------------------------------------------------------

fn run_listen_mode(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let identity = Identity::generate()?;
    let trust_store = Arc::new(InMemoryTrustStore::new());
    let rate_limiter = Arc::new(PairingRateLimiter::default_config());
    let pin = random_pin();
    let server_config = Arc::new(tls::server_config(&identity)?);

    let listener = TcpListener::bind(("0.0.0.0", port))?;
    let bound = listener.local_addr()?;
    println!("Sidewire Display (Rust) — listening on {bound}");
    println!("  device id : {}", identity.device_id);
    println!("  pairing PIN: {pin}   (enter this on the Source Mac)");
    println!("  a window opens once a Source connects and streaming begins.");

    window::run("Sidewire — Display", move |producer: FrameProducer| {
        let (tcp, peer_addr) = match listener.accept() {
            Ok(v) => v,
            Err(e) => {
                eprintln!("accept failed: {e}");
                producer.close();
                return;
            }
        };
        println!("accepted connection from {peer_addr}");

        let (wire, tls_info) = match Wire::accept(server_config, tcp, &identity) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("TLS accept failed: {e}");
                producer.close();
                return;
            }
        };
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
        let pairing = PairingConfig::new(pin, trust_store.clone(), Some(rate_limiter));
        let session = Session::new(
            Role::Display,
            hello,
            Some(display_info()),
            wire,
            tls_info,
            pairing,
        );

        let mut decoder: Option<Decoder> = None;
        let mut decoder_failed = false;
        let mut tracker = LatencyTracker::new(120);
        let outcome = session.run_streaming(|nal, keyframe, pts| {
            if decoder_failed {
                return; // a prior init failure already asked the window to close
            }
            let recv = Instant::now();
            // Build the decoder from the codec carried in-band by the first keyframe's parameter
            // sets (docs/04) — equivalent to the negotiated CONFIG.codec for this stream. Fail loud
            // (log + close the window) rather than panicking the worker thread (which would leave the
            // window hung) or silently mis-decoding as the wrong codec.
            if decoder.is_none() {
                let codec = match detect_codec(nal) {
                    Some(c) => c,
                    None => {
                        eprintln!("could not determine codec from the first access unit; closing");
                        decoder_failed = true;
                        producer.close();
                        return;
                    }
                };
                match Decoder::new(codec) {
                    Ok(d) => {
                        println!("decoding {codec:?} stream");
                        decoder = Some(d);
                    }
                    Err(e) => {
                        eprintln!("decoder init failed: {e}");
                        decoder_failed = true;
                        producer.close();
                        return;
                    }
                }
            }
            let dec = decoder.as_mut().expect("decoder set above");
            let frames = dec
                .decode_access_unit(nal, keyframe, pts)
                .unwrap_or_default();
            let decoded_at = Instant::now();
            for f in frames {
                let present_start = Instant::now();
                let alive = producer.post(f);
                tracker.record(FrameStats {
                    wire_pts_nanos: pts,
                    recv_to_decode: decoded_at - recv,
                    decode_to_present: present_start.elapsed(),
                });
                if tracker.total_frames().is_multiple_of(30) {
                    println!("{}", tracker.summary_line());
                }
                if !alive {
                    break;
                }
            }
        });
        producer.close();
        println!(
            "session ended: reason = {}, frames decoded = {}",
            outcome.close_reason.as_deref().unwrap_or("<none>"),
            tracker.total_frames()
        );
    })?;
    Ok(())
}

// ---------------------------------------------------------------------------
// --handshake-only: the preserved M1 behavior (no window)
// ---------------------------------------------------------------------------

fn run_handshake_only(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let identity = Identity::generate()?;
    let trust_store = Arc::new(InMemoryTrustStore::new());
    let rate_limiter = Arc::new(PairingRateLimiter::default_config());
    let pin = random_pin();
    let server_config = Arc::new(tls::server_config(&identity)?);

    let listener = TcpListener::bind(("0.0.0.0", port))?;
    let bound = listener.local_addr()?;
    println!("Sidewire Display (Rust) — handshake-only (M1) on {bound}");
    println!("  device id : {}", identity.device_id);
    println!("  pairing PIN: {pin}   (enter this on the Source Mac)");

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
    let pairing = PairingConfig::new(pin, trust_store.clone(), Some(rate_limiter));
    let session = Session::new(
        Role::Display,
        hello,
        Some(display_info()),
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
        None => println!(
            "session closed before CONFIG: reason = {}",
            outcome.close_reason.as_deref().unwrap_or("<none>")
        ),
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

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

fn display_info() -> DisplayInfo {
    DisplayInfo {
        width: 2560,
        height: 1600,
        scale_factor: 2.0,
        refresh_rate: 60.0,
        name: "Sidewire Rust Display".to_string(),
    }
}

/// A random 6-digit pairing PIN. M2 uses a fresh one per launch; rotation UX comes later.
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
