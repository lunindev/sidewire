//! Conformance tests against the language-neutral golden vectors in `protocol-vectors/`.
//!
//! `frame`/`input`/`video` vectors are matched **byte-exact** (encode → assert equals the expected
//! hex, and decode → assert the fields round-trip). `message` (JSON) vectors are matched
//! **semantically** (decode into our structs, re-encode, assert the fields survive) because JSON
//! key order is not significant. If a byte-exact vector fails, the *implementation* is wrong — the
//! vectors are the fixed conformance target (do not edit them).

use std::path::PathBuf;

use serde_json::Value;
use sidewire_proto::{
    Capabilities, Config, DisplayInfo, Frame, FrameParser, Hello, InputEventRecord, InputEventType,
    ReasonMessage, Role, VideoPayload,
};

fn vectors_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../protocol-vectors")
}

fn load(name: &str) -> Value {
    let path = vectors_dir().join(name);
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

fn hexd(s: &str) -> Vec<u8> {
    hex::decode(s).expect("valid hex")
}

// ---------------------------------------------------------------------------
// frame-vectors.json — byte-exact
// ---------------------------------------------------------------------------

#[test]
fn frame_vectors_encode_and_decode() {
    let doc = load("frame-vectors.json");
    let vectors = doc["vectors"].as_array().expect("vectors array");
    assert!(!vectors.is_empty());

    for v in vectors {
        let name = v["name"].as_str().unwrap();
        let raw_type = v["type"].as_u64().unwrap() as u8;
        let flags = v["flags"].as_u64().unwrap() as u8;
        let seq = v["seq"].as_u64().unwrap() as u32;
        let payload = hexd(v["payloadHex"].as_str().unwrap());
        let expected = hexd(v["frameHex"].as_str().unwrap());

        // Encode → byte-exact.
        let frame = Frame::new(raw_type, flags, seq, payload.clone());
        assert_eq!(
            frame.encode(),
            expected,
            "frame '{name}' encoding must match frameHex"
        );

        // Decode (fed as a single chunk) → fields round-trip.
        let mut parser = FrameParser::new();
        let frames = parser.append(&expected).expect("parse");
        assert_eq!(frames.len(), 1, "frame '{name}' should parse to one frame");
        let got = &frames[0];
        assert_eq!(got.raw_type, raw_type, "frame '{name}' type");
        assert_eq!(got.flags, flags, "frame '{name}' flags");
        assert_eq!(got.seq, seq, "frame '{name}' seq");
        assert_eq!(got.payload, payload, "frame '{name}' payload");
        assert_eq!(parser.pending_byte_count(), 0);
    }
}

#[test]
fn frame_parser_handles_split_chunks_and_unknown_types() {
    // The "unknown_reserved_type" (0x7A) vector must parse like any other frame.
    let doc = load("frame-vectors.json");
    let v = doc["vectors"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["name"] == "unknown_reserved_type")
        .expect("unknown_reserved_type vector present");
    let bytes = hexd(v["frameHex"].as_str().unwrap());

    // Feed the frame one byte at a time — only the last byte completes it.
    let mut parser = FrameParser::new();
    let mut produced = Vec::new();
    for (i, b) in bytes.iter().enumerate() {
        let frames = parser.append(&[*b]).unwrap();
        if i + 1 < bytes.len() {
            assert!(frames.is_empty(), "partial frame must not yield early");
        }
        produced.extend(frames);
    }
    assert_eq!(produced.len(), 1);
    assert_eq!(produced[0].raw_type, 0x7A);
    assert!(
        produced[0].message_type().is_none(),
        "0x7A is unknown/reserved"
    );
    assert_eq!(produced[0].payload, hexd("deadbeef"));
}

#[test]
fn frame_parser_rejects_oversized_length() {
    // A header claiming > 16 MiB payload must be rejected (guards allocation).
    // type=0x10, flags=0, reserved=0, length=0x0100_0001 (16 MiB + 1), seq=0.
    let mut header = vec![0x10u8, 0x00, 0x00, 0x00];
    header.extend_from_slice(&(16u32 * 1024 * 1024 + 1).to_be_bytes());
    header.extend_from_slice(&0u32.to_be_bytes());
    let mut parser = FrameParser::new();
    let err = parser
        .append(&header)
        .expect_err("must reject oversized length");
    assert_eq!(
        err,
        sidewire_proto::ParseError::FrameTooLarge(16 * 1024 * 1024 + 1)
    );
}

// ---------------------------------------------------------------------------
// input-vectors.json — byte-exact
// ---------------------------------------------------------------------------

#[test]
fn input_vectors_encode_and_decode() {
    let doc = load("input-vectors.json");
    let vectors = doc["vectors"].as_array().expect("vectors array");
    assert!(!vectors.is_empty());

    for v in vectors {
        let name = v["name"].as_str().unwrap();
        let event_type = InputEventType::from_u8(v["eventType"].as_u64().unwrap() as u8)
            .expect("known event type");
        let rec = InputEventRecord {
            event_type,
            button_number: v["buttonNumber"].as_u64().unwrap() as u8,
            click_count: v["clickCount"].as_u64().unwrap() as u8,
            modifiers: v["modifiers"].as_u64().unwrap() as u8,
            x: v["x"].as_f64().unwrap() as f32,
            y: v["y"].as_f64().unwrap() as f32,
            delta_x: v["deltaX"].as_f64().unwrap() as f32,
            delta_y: v["deltaY"].as_f64().unwrap() as f32,
            key_code: v["keyCode"].as_u64().unwrap() as u16,
        };
        let expected = hexd(v["hex"].as_str().unwrap());
        assert_eq!(
            rec.encode().to_vec(),
            expected,
            "input '{name}' encoding must match hex"
        );

        // Decode → identical record (exercises the float round-trip too).
        let decoded = InputEventRecord::decode(&expected).expect("decode");
        assert_eq!(decoded, rec, "input '{name}' decode round-trip");
    }
}

#[test]
fn input_decode_batch() {
    // Two records concatenated decode into two.
    let doc = load("input-vectors.json");
    let vectors = doc["vectors"].as_array().unwrap();
    let a = hexd(vectors[0]["hex"].as_str().unwrap());
    let b = hexd(vectors[1]["hex"].as_str().unwrap());
    let mut both = a.clone();
    both.extend_from_slice(&b);
    let recs = InputEventRecord::decode_batch(&both);
    assert_eq!(recs.len(), 2);
    assert_eq!(recs[0].encode().to_vec(), a);
    assert_eq!(recs[1].encode().to_vec(), b);
}

// ---------------------------------------------------------------------------
// video-vectors.json — byte-exact
// ---------------------------------------------------------------------------

#[test]
fn video_vectors_encode_and_decode() {
    let doc = load("video-vectors.json");
    let vectors = doc["vectors"].as_array().expect("vectors array");
    assert!(!vectors.is_empty());

    for v in vectors {
        let name = v["name"].as_str().unwrap();
        let ltr_token = v["ltrToken"].as_u64().unwrap() as u16;
        let pts = v["ptsNanos"].as_u64().unwrap();
        let nal = hexd(v["nalHex"].as_str().unwrap());
        let expected = hexd(v["payloadHex"].as_str().unwrap());

        assert_eq!(
            VideoPayload::encode(ltr_token, pts, &nal),
            expected,
            "video '{name}' payload must match payloadHex"
        );

        let (dtoken, dpts, dnal) = VideoPayload::decode(&expected).expect("decode");
        assert_eq!(dtoken, ltr_token, "video '{name}' ltrToken");
        assert_eq!(dpts, pts, "video '{name}' pts");
        assert_eq!(dnal, nal, "video '{name}' nal");
    }
}

// ---------------------------------------------------------------------------
// message-vectors.json — semantic
// ---------------------------------------------------------------------------

/// Decode the vector's `message` object into `T`, re-encode, and re-decode: the fields must
/// survive the round-trip through our JSON codec (JSON key order is not significant).
fn assert_semantic_roundtrip<T>(message: &Value) -> T
where
    T: serde::de::DeserializeOwned + serde::Serialize + PartialEq + std::fmt::Debug,
{
    let decoded: T = serde_json::from_value(message.clone()).expect("decode message");
    let reencoded = serde_json::to_value(&decoded).expect("encode");
    let redecoded: T = serde_json::from_value(reencoded).expect("re-decode");
    assert_eq!(
        decoded, redecoded,
        "semantic round-trip must preserve fields"
    );
    decoded
}

#[test]
fn message_vectors_semantic_roundtrip() {
    let doc = load("message-vectors.json");

    // HELLO
    let hello_msg = &doc["hello"].as_array().unwrap()[0]["message"];
    let hello: Hello = assert_semantic_roundtrip(hello_msg);
    assert_eq!(hello.magic, "SIDEWIRE");
    assert_eq!(hello.version.major, 2);
    assert_eq!(hello.role, Role::Source);
    assert_eq!(hello.capabilities.input_mapping, "hid1");
    assert_eq!(hello.capabilities.video_codecs, vec!["hevc", "h264"]);
    // A source HELLO validated against a Display peer must be accepted.
    assert!(hello.validate(Role::Display).is_none());

    // CONFIG
    let config_msg = &doc["config"].as_array().unwrap()[0]["message"];
    let config: Config = assert_semantic_roundtrip(config_msg);
    assert_eq!(config.codec, "hevc");
    assert_eq!(config.width, 2560);
    assert_eq!(config.height, 1600);
    assert_eq!(config.fps, 60);
    assert!(config.hi_dpi);

    // DISPLAY_INFO
    let di_msg = &doc["displayInfo"].as_array().unwrap()[0]["message"];
    let di: DisplayInfo = assert_semantic_roundtrip(di_msg);
    assert_eq!(di.width, 2560);
    assert_eq!(di.scale_factor, 2.0);
    assert_eq!(di.refresh_rate, 60.0);

    // BYE
    for entry in doc["bye"].as_array().unwrap() {
        let bye: ReasonMessage = assert_semantic_roundtrip(&entry["message"]);
        assert_eq!(bye.reason, entry["message"]["reason"].as_str().unwrap());
    }
}

#[test]
fn optional_fields_default_when_absent() {
    // capabilities.inputMapping absent ⇒ "hid1".
    let caps_json = serde_json::json!({
        "videoCodecs": ["hevc"],
        "maxWidth": 1920, "maxHeight": 1080, "maxFps": 60,
        "ltr": false, "audio": false, "hdr": false
        // inputMapping deliberately omitted
    });
    let caps: Capabilities = serde_json::from_value(caps_json).unwrap();
    assert_eq!(caps.input_mapping, "hid1", "absent inputMapping ⇒ hid1");

    // config.hiDPI absent ⇒ true.
    let config_json = serde_json::json!({
        "codec": "h264", "width": 1280, "height": 720, "fps": 30, "ltr": false,
        "bitrateStartBps": 1, "bitrateMinBps": 1, "bitrateMaxBps": 1
        // hiDPI deliberately omitted
    });
    let config: Config = serde_json::from_value(config_json).unwrap();
    assert!(config.hi_dpi, "absent hiDPI ⇒ true");
}

#[test]
fn config_hidpi_json_key_and_nondefault_roundtrip() {
    // Pin the exact wire key name `hiDPI`. serde's camelCase of `hi_dpi` would be `hiDpi`, so the
    // explicit rename is load-bearing for interop — and the config vector (hiDPI:true == default)
    // does NOT exercise a non-default value, so a regression to the wrong key would slip past it.
    let cfg = Config {
        codec: "h264".into(),
        width: 1280,
        height: 720,
        fps: 30,
        ltr: false,
        bitrate_start_bps: 1,
        bitrate_min_bps: 1,
        bitrate_max_bps: 1,
        hi_dpi: false,
    };
    let v = serde_json::to_value(&cfg).unwrap();
    assert!(
        v.get("hiDPI").is_some(),
        "Config must serialize the key as `hiDPI`"
    );
    assert!(
        v.get("hiDpi").is_none(),
        "must NOT use serde camelCase `hiDpi`"
    );
    assert_eq!(v["hiDPI"], serde_json::json!(false));
    let back: Config = serde_json::from_value(v).unwrap();
    assert_eq!(back, cfg, "hiDPI=false must round-trip");
}

#[test]
fn optional_fields_tolerate_explicit_null() {
    // Swift's `Bool?` / `decodeIfPresent` read an explicit JSON null as the default; match that so
    // a foreign encoder that writes `null` (rather than omitting the key) is accepted, not rejected.
    let caps_json = serde_json::json!({
        "videoCodecs": ["hevc"], "maxWidth": 1920, "maxHeight": 1080, "maxFps": 60,
        "ltr": false, "audio": false, "hdr": false, "inputMapping": null
    });
    let caps: Capabilities =
        serde_json::from_value(caps_json).expect("explicit null inputMapping ⇒ default");
    assert_eq!(caps.input_mapping, "hid1");

    let config_json = serde_json::json!({
        "codec": "h264", "width": 1, "height": 1, "fps": 1, "ltr": false,
        "bitrateStartBps": 1, "bitrateMinBps": 1, "bitrateMaxBps": 1, "hiDPI": null
    });
    let config: Config =
        serde_json::from_value(config_json).expect("explicit null hiDPI ⇒ default");
    assert!(config.hi_dpi);
}

#[test]
fn decoder_ignores_unknown_fields() {
    // A HELLO with an extra unknown key must still decode (forward compatibility).
    let doc = load("message-vectors.json");
    let mut hello_msg = doc["hello"].as_array().unwrap()[0]["message"].clone();
    hello_msg["someFutureField"] = Value::from(true);
    hello_msg["capabilities"]["futureCap"] = Value::from(42);
    let hello: Hello = serde_json::from_value(hello_msg).expect("unknown fields ignored");
    assert_eq!(hello.role, Role::Source);
}
