//! End-to-end M2 integration over **real TLS 1.3** on `127.0.0.1`: a Rust Source peer replays a
//! fixture clip as `VIDEO` frames after CONFIG, and the Rust Display receives them via
//! `Session::run_streaming`, decodes each with `sidewire-media`, and we assert the decoded frames.
//!
//! This is the strongest M2 test that needs no live Mac: it exercises the whole receive→parse→decode
//! path (framing, VIDEO subheader + keyframe bit, PTS carry-through) through an actual rustls
//! session. Requires libavcodec 7.x (see the crate README for the macOS ffmpeg@7 env).

use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::time::Duration;

use sidewire_crypto::Identity;
use sidewire_media::{split_access_units, Codec, Decoder};
use sidewire_proto::{Capabilities, DisplayInfo, Hello, Role};
use sidewire_viewer::session::{HeartbeatConfig, OutgoingVideo, PairingConfig, Session};
use sidewire_viewer::tls;
use sidewire_viewer::trust_store::InMemoryTrustStore;
use sidewire_viewer::wire::Wire;

fn caps(codec: &str) -> Capabilities {
    Capabilities::new(vec![codec.to_string()], 3840, 2160, 60, false, false, false)
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

fn fixture(name: &str) -> Vec<u8> {
    // The fixtures live in the sibling sidewire-media crate.
    let path = format!(
        "{}/../sidewire-media/tests/fixtures/{}",
        env!("CARGO_MANIFEST_DIR"),
        name
    );
    std::fs::read(&path).unwrap_or_else(|e| panic!("read fixture {path}: {e}"))
}

/// One decoded frame's observable properties, collected by the Display callback.
#[derive(Debug, Clone, Copy, PartialEq)]
struct FrameInfo {
    width: u32,
    height: u32,
    pts: u64,
    keyframe_seen: bool,
}

/// Run the whole Source→Display video path for one codec/fixture and return the Display's decoded
/// frames plus both sessions' negotiated codecs.
fn run_video_loopback(fixture_name: &str, codec_name: &str, codec: Codec) -> Vec<FrameInfo> {
    let display_id = Identity::generate().unwrap();
    let source_id = Identity::generate().unwrap();
    let server_cfg = Arc::new(tls::server_config(&display_id).unwrap());
    let client_cfg = Arc::new(tls::client_config(&source_id).unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();

    let display_trust = Arc::new(InMemoryTrustStore::new());
    let source_trust = Arc::new(InMemoryTrustStore::new());
    let pin = "424242".to_string();

    // --- Display thread: accept, reach CONFIG, stream + decode VIDEO frames. ---
    let d_codec = codec;
    let d_codec_name = codec_name.to_string();
    let d_pin = pin.clone();
    let display = std::thread::spawn(move || {
        let (tcp, _) = listener.accept().expect("accept");
        tcp.set_read_timeout(Some(Duration::from_secs(15))).ok();
        let (wire, tls_info) = Wire::accept(server_cfg, tcp, &display_id).expect("display TLS");
        let hello = Hello::new(
            Role::Display,
            display_id.device_id.clone(),
            "RustDisplay",
            "sess-d",
            caps(&d_codec_name),
        );
        let pairing = PairingConfig::new(d_pin, display_trust, None);
        let session = Session::new(
            Role::Display,
            hello,
            Some(display_info()),
            wire,
            tls_info,
            pairing,
        );

        let mut decoder = Decoder::new(d_codec).expect("build decoder");
        let mut frames: Vec<FrameInfo> = Vec::new();
        // No captured input in this video-only test: a live-but-empty channel (the sender is held so
        // the receiver never disconnects). Default heartbeat is fine — the clip streams in ms.
        let (_input_tx, input_rx) = std::sync::mpsc::channel();
        let outcome = session.run_streaming(
            &input_rx,
            HeartbeatConfig::default(),
            |nal, keyframe, pts| {
                let decoded = decoder
                    .decode_access_unit(nal, keyframe, pts)
                    .expect("decode AU");
                for f in decoded {
                    frames.push(FrameInfo {
                        width: f.width,
                        height: f.height,
                        pts: f.pts_nanos,
                        keyframe_seen: keyframe,
                    });
                }
            },
        );
        (outcome, frames)
    });

    // --- Source: connect, reach CONFIG, replay the fixture as VIDEO frames. ---
    let data = fixture(fixture_name);
    let aus = split_access_units(&data, codec);
    assert_eq!(aus.len(), 5, "fixture should split into 5 AUs");
    let outgoing: Vec<OutgoingVideo> = aus
        .iter()
        .enumerate()
        .map(|(i, au)| OutgoingVideo {
            nal: au.data.clone(),
            keyframe: au.keyframe,
            pts_nanos: (i as u64) * 33_000_000,
        })
        .collect();

    let tcp = TcpStream::connect(addr).expect("tcp connect");
    tcp.set_read_timeout(Some(Duration::from_secs(15))).ok();
    let (wire, tls_info) = Wire::connect(client_cfg, tcp, &source_id).expect("source TLS");
    let hello = Hello::new(
        Role::Source,
        source_id.device_id.clone(),
        "RustSource",
        "sess-s",
        caps(codec_name),
    );
    let pairing = PairingConfig::new(pin, source_trust, None);
    let source_outcome = Session::new(Role::Source, hello, None, wire, tls_info, pairing)
        .run_sending_video(&outgoing);

    let (display_outcome, frames) = display.join().unwrap();

    // Both peers reached CONFIG on the expected codec.
    assert_eq!(
        source_outcome.config.as_ref().map(|c| c.codec.as_str()),
        Some(codec_name),
        "source negotiated codec"
    );
    assert_eq!(
        display_outcome.config.as_ref().map(|c| c.codec.as_str()),
        Some(codec_name),
        "display negotiated codec"
    );
    // The Source closed the stream cleanly with BYE("user").
    assert_eq!(display_outcome.close_reason.as_deref(), Some("user"));

    frames
}

fn assert_five_frames(frames: &[FrameInfo]) {
    assert_eq!(frames.len(), 5, "5 frames decoded end-to-end");
    for (i, f) in frames.iter().enumerate() {
        assert_eq!(f.width, 320, "frame {i} width");
        assert_eq!(f.height, 240, "frame {i} height");
        assert_eq!(f.pts, (i as u64) * 33_000_000, "frame {i} wire PTS carried");
    }
    assert!(frames[0].keyframe_seen, "the first AU was flagged keyframe");
    assert!(
        frames[1..].iter().all(|f| !f.keyframe_seen),
        "only the first AU is a keyframe"
    );
}

#[test]
fn h264_streams_and_decodes_end_to_end() {
    let frames = run_video_loopback("clip.h264", "h264", Codec::H264);
    assert_five_frames(&frames);
}

#[test]
fn hevc_streams_and_decodes_end_to_end() {
    let frames = run_video_loopback("clip.h265", "hevc", Codec::Hevc);
    assert_five_frames(&frames);
}
