//! Decode the committed Annex-B fixtures through `sidewire-media`, exactly as the wire path would:
//! split each clip into access units and feed them one at a time (as a `VIDEO` payload's NAL data),
//! asserting frame count, dimensions, pixel format, and PTS carry-through.
//!
//! Requires libavcodec 7.x at build+run time (see the crate README for the macOS ffmpeg@7 env). If
//! ffmpeg is absent the crate won't compile — expected; this test just needs that env.

use sidewire_media::{split_access_units, Codec, Decoder, PixelFormat};

fn fixture(name: &str) -> Vec<u8> {
    let path = format!("{}/tests/fixtures/{}", env!("CARGO_MANIFEST_DIR"), name);
    std::fs::read(&path).unwrap_or_else(|e| panic!("read fixture {path}: {e}"))
}

/// Split a fixture into access units and decode each, stamping a synthetic monotonic wire PTS
/// (33 ms apart) so we can assert the decoder carries it through unchanged.
fn decode_clip(name: &str, codec: Codec) -> Vec<sidewire_media::DecodedFrame> {
    let data = fixture(name);
    let aus = split_access_units(&data, codec);
    assert_eq!(aus.len(), 5, "{name}: expected 5 access units");
    assert!(aus[0].keyframe, "{name}: AU 0 must be a keyframe");
    assert!(
        aus[1..].iter().all(|a| !a.keyframe),
        "{name}: only AU 0 is a keyframe"
    );

    let mut decoder = Decoder::new(codec).expect("build decoder");
    let mut frames = Vec::new();
    for (i, au) in aus.iter().enumerate() {
        let pts = (i as u64) * 33_000_000; // 33 ms in nanoseconds
        let out = decoder
            .decode_access_unit(&au.data, au.keyframe, pts)
            .expect("decode AU");
        frames.extend(out);
    }
    frames
}

fn assert_frames(name: &str, frames: &[sidewire_media::DecodedFrame]) {
    assert_eq!(frames.len(), 5, "{name}: expected 5 decoded frames");
    for (i, f) in frames.iter().enumerate() {
        assert_eq!(f.width, 320, "{name} frame {i}: width");
        assert_eq!(f.height, 240, "{name} frame {i}: height");
        assert_eq!(
            f.format,
            PixelFormat::Yuv420p,
            "{name} frame {i}: software decode yields YUV420P"
        );
        assert_eq!(
            f.planes.len(),
            3,
            "{name} frame {i}: YUV420P has three planes"
        );
        // Y plane full size; chroma planes half size, each with a valid stride and enough data.
        assert_eq!(f.planes[0].width, 320);
        assert_eq!(f.planes[0].height, 240);
        assert_eq!(f.planes[1].width, 160);
        assert_eq!(f.planes[1].height, 120);
        for (p, plane) in f.planes.iter().enumerate() {
            assert!(
                plane.stride >= plane.width,
                "{name} frame {i} plane {p}: stride >= width"
            );
            assert!(
                plane.data.len() >= plane.stride * plane.height,
                "{name} frame {i} plane {p}: data holds every row"
            );
        }
        // The wire PTS was carried through verbatim, in submission order (no B-frames).
        assert_eq!(
            f.pts_nanos,
            (i as u64) * 33_000_000,
            "{name} frame {i}: wire PTS carried through"
        );
    }
}

#[test]
fn decodes_h264_fixture() {
    let frames = decode_clip("clip.h264", Codec::H264);
    assert_frames("clip.h264", &frames);
}

#[test]
fn decodes_hevc_fixture() {
    let frames = decode_clip("clip.h265", Codec::Hevc);
    assert_frames("clip.h265", &frames);
}

#[test]
fn drops_frames_before_first_keyframe() {
    // Feed a non-keyframe AU first: the decoder must not start (cannot join mid-GOP).
    let data = fixture("clip.h264");
    let aus = split_access_units(&data, Codec::H264);
    let mut decoder = Decoder::new(Codec::H264).expect("build decoder");

    let out = decoder
        .decode_access_unit(&aus[1].data, false, 0)
        .expect("decode");
    assert!(out.is_empty(), "a pre-keyframe AU yields no frame");
    assert!(
        !decoder.is_started(),
        "decoder stays un-started until a keyframe"
    );

    // Now the keyframe starts it.
    let out = decoder
        .decode_access_unit(&aus[0].data, true, 111)
        .expect("decode keyframe");
    assert_eq!(out.len(), 1, "keyframe decodes to one frame");
    assert_eq!(out[0].pts_nanos, 111);
    assert!(decoder.is_started());
}
