//! Annex-B access-unit splitting — pure Rust, no ffmpeg.
//!
//! The Sidewire video stream is **clean Annex-B H.264/HEVC**, one slice per picture, no B-frames,
//! parameter sets in-band at every IDR (docs/04-media-pipeline.md). On the wire each `VIDEO` frame
//! payload is a single self-contained access unit (docs/02 § VIDEO). This module splits a raw
//! Annex-B bitstream into those access units, which is what a test/demo needs to *replay* a `.h264`
//! / `.h265` file as if it had arrived frame-by-frame over the wire. (Live decode does not use this
//! — it receives AUs already split by the sender.)
//!
//! Start codes may be 3-byte (`00 00 01`) or 4-byte (`00 00 00 01`); both occur in real streams
//! (e.g. an SEI often follows a 3-byte code). Access-unit boundaries are detected heuristically:
//! a run of leading non-VCL NALs (parameter sets, SEI, AUD) is grouped with the next VCL slice
//! NAL, and a new AU starts at the next VCL NAL. This is exact for this stream shape (one slice per
//! picture). Each AU keeps its original start codes so it can be fed straight to a decoder.

/// The elementary-stream codec of an Annex-B bitstream. Determines how a NAL header byte is parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    /// H.264 / AVC. NAL type = `header[0] & 0x1F`.
    H264,
    /// H.265 / HEVC. NAL type = `(header[0] >> 1) & 0x3F`.
    Hevc,
}

impl Codec {
    /// Parse a codec from the `CONFIG.codec` string (docs/02 § CONFIG). Case-insensitive.
    pub fn from_name(name: &str) -> Option<Codec> {
        match name.to_ascii_lowercase().as_str() {
            "h264" | "avc" => Some(Codec::H264),
            "hevc" | "h265" => Some(Codec::Hevc),
            _ => None,
        }
    }
}

/// One access unit extracted from an Annex-B stream.
#[derive(Debug, Clone)]
pub struct AccessUnit {
    /// The AU's raw Annex-B bytes, start codes included — ready to feed to a decoder / send as a
    /// `VIDEO` payload's NAL data.
    pub data: Vec<u8>,
    /// True if this AU carries parameter sets / an IDR — i.e. a stream can join here. Maps to the
    /// FRAME `flags` keyframe bit (`0x01`, docs/02 § VIDEO).
    pub keyframe: bool,
}

/// Best-effort detect the codec of a raw Annex-B buffer from its NAL header bytes. Recognizes HEVC
/// VPS/SPS/PPS (types 32–34) and H.264 SPS/PPS (types 7–8), which are in-band at every keyframe
/// (docs/04). Returns `None` if no parameter-set NAL is found. Used by the listen demo, which learns
/// the codec from the first access unit; the negotiated `CONFIG.codec` is authoritative when known.
pub fn detect_codec(data: &[u8]) -> Option<Codec> {
    for (off, len) in start_codes(data) {
        let Some(&h) = data.get(off + len) else {
            continue;
        };
        // A NAL header's forbidden_zero_bit (0x80) is always clear in valid streams.
        if h & 0x80 != 0 {
            continue;
        }
        let hevc_type = (h >> 1) & 0x3F;
        if (32..=34).contains(&hevc_type) {
            return Some(Codec::Hevc);
        }
        let h264_type = h & 0x1F;
        if h264_type == 7 || h264_type == 8 {
            return Some(Codec::H264);
        }
    }
    None
}

/// A NAL unit located within the source buffer.
struct Nal {
    /// Offset of the start code (the AU/NAL begins here, start code included).
    start: usize,
    /// Offset one past the end of this NAL (exclusive).
    end: usize,
    /// NAL type, already decoded per codec.
    nal_type: u8,
}

/// Locate every start code in `data`, returning `(offset, start_code_len)` pairs in order.
fn start_codes(data: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            out.push((i, 3));
            i += 3;
        } else if i + 4 <= data.len()
            && data[i] == 0
            && data[i + 1] == 0
            && data[i + 2] == 0
            && data[i + 3] == 1
        {
            out.push((i, 4));
            i += 4;
        } else {
            i += 1;
        }
    }
    out
}

/// Split `data` into NAL units (each spanning from its start code to the next).
fn nals(data: &[u8], codec: Codec) -> Vec<Nal> {
    let codes = start_codes(data);
    let mut out = Vec::with_capacity(codes.len());
    for (k, &(off, len)) in codes.iter().enumerate() {
        let payload_start = off + len;
        let end = codes.get(k + 1).map(|&(o, _)| o).unwrap_or(data.len());
        if payload_start >= end {
            continue; // empty NAL (e.g. trailing start code) — skip
        }
        let header = data[payload_start];
        let nal_type = match codec {
            Codec::H264 => header & 0x1F,
            Codec::Hevc => (header >> 1) & 0x3F,
        };
        out.push(Nal {
            start: off,
            end,
            nal_type,
        });
    }
    out
}

/// True for a VCL (slice) NAL — the NAL that actually carries picture data.
fn is_vcl(codec: Codec, nal_type: u8) -> bool {
    match codec {
        Codec::H264 => (1..=5).contains(&nal_type),
        // HEVC VCL NAL types are 0..=31; 32+ are non-VCL (VPS/SPS/PPS/SEI/…).
        Codec::Hevc => nal_type <= 31,
    }
}

/// True if a NAL is a parameter set or an IDR VCL — i.e. an access unit containing it is a keyframe
/// (a valid stream join point). Parameter sets are in-band at every IDR (docs/04).
fn is_keyframe_nal(codec: Codec, nal_type: u8) -> bool {
    match codec {
        // SPS(7) / PPS(8) / IDR slice(5).
        Codec::H264 => nal_type == 7 || nal_type == 8 || nal_type == 5,
        // VPS(32) / SPS(33) / PPS(34), or an IRAP VCL (BLA/IDR/CRA = 16..=23).
        Codec::Hevc => (32..=34).contains(&nal_type) || (16..=23).contains(&nal_type),
    }
}

/// Split a raw Annex-B bitstream into access units, one per coded picture.
///
/// Returns an empty vec if `data` contains no NAL units. Each returned [`AccessUnit`] retains its
/// original start codes and is flagged `keyframe` if it carries parameter sets / an IDR.
pub fn split_access_units(data: &[u8], codec: Codec) -> Vec<AccessUnit> {
    let nals = nals(data, codec);
    if nals.is_empty() {
        return Vec::new();
    }

    let mut units = Vec::new();
    let mut au_start: Option<usize> = None;
    let mut au_end = 0usize;
    let mut au_has_vcl = false;
    let mut au_keyframe = false;

    for nal in &nals {
        let vcl = is_vcl(codec, nal.nal_type);
        if vcl && au_has_vcl {
            // A second VCL NAL means a new picture — flush the current AU.
            if let Some(start) = au_start {
                units.push(AccessUnit {
                    data: data[start..au_end].to_vec(),
                    keyframe: au_keyframe,
                });
            }
            au_start = None;
            au_has_vcl = false;
            au_keyframe = false;
        }
        if au_start.is_none() {
            au_start = Some(nal.start);
        }
        au_end = nal.end;
        if vcl {
            au_has_vcl = true;
        }
        if is_keyframe_nal(codec, nal.nal_type) {
            au_keyframe = true;
        }
    }
    if let Some(start) = au_start {
        units.push(AccessUnit {
            data: data[start..au_end].to_vec(),
            keyframe: au_keyframe,
        });
    }
    units
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_two_start_code_lengths() {
        // SPS (4-byte code), then a slice preceded by a 3-byte code.
        let data = [
            0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, // SPS
            0x00, 0x00, 0x01, 0x65, 0xBB, // IDR slice (3-byte start code)
            0x00, 0x00, 0x00, 0x01, 0x41, 0xCC, // non-IDR slice
        ];
        let aus = split_access_units(&data, Codec::H264);
        assert_eq!(aus.len(), 2);
        assert!(aus[0].keyframe); // SPS + IDR
        assert!(!aus[1].keyframe);
        // The first AU spans the SPS and the IDR slice, start codes intact.
        assert_eq!(aus[0].data[0..4], [0x00, 0x00, 0x00, 0x01]);
    }

    #[test]
    fn empty_input_yields_nothing() {
        assert!(split_access_units(&[], Codec::H264).is_empty());
        assert!(split_access_units(&[0x00, 0x00], Codec::Hevc).is_empty());
    }

    #[test]
    fn detects_codec_from_parameter_sets() {
        // H.264 SPS (0x67).
        let h264 = [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00];
        assert_eq!(detect_codec(&h264), Some(Codec::H264));
        // HEVC VPS (0x40).
        let hevc = [0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C];
        assert_eq!(detect_codec(&hevc), Some(Codec::Hevc));
        // No parameter set present (0x01 = non-param-set NAL under either codec interpretation).
        let none = [0x00, 0x00, 0x00, 0x01, 0x01, 0x9A];
        assert_eq!(detect_codec(&none), None);
    }
}
