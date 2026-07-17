//! Binary hot-path payloads: VIDEO subheader + Annex-B, PING/PONG heartbeat, LTR_ACK.
//! Mirrors `VideoPayload.swift`. All integers big-endian.

use crate::constants::VIDEO_SUBHEADER_BYTES;

/// The VIDEO payload = a 12-byte subheader + Annex-B NAL data.
///
/// Subheader layout (big-endian): `ltrToken:u16 | flags:u16(=0) | pts:u64`. `pts` is the capture
/// presentation timestamp in nanoseconds on the source's arbitrary monotonic epoch (0 =
/// unspecified). The keyframe bit lives in the *frame* header flags, not here.
pub struct VideoPayload;

impl VideoPayload {
    /// Build a VIDEO payload: 12-byte subheader + Annex-B NAL bytes.
    pub fn encode(ltr_token: u16, pts_nanos: u64, nal_data: &[u8]) -> Vec<u8> {
        let mut d = Vec::with_capacity(VIDEO_SUBHEADER_BYTES + nal_data.len());
        d.extend_from_slice(&ltr_token.to_be_bytes());
        d.extend_from_slice(&0u16.to_be_bytes()); // flags (reserved)
        d.extend_from_slice(&pts_nanos.to_be_bytes()); // capture PTS, nanoseconds
        d.extend_from_slice(nal_data);
        d
    }

    /// Split a VIDEO payload into `(ltr_token, pts_nanos, nal_bytes)`. Returns `None` if malformed.
    pub fn decode(payload: &[u8]) -> Option<(u16, u64, Vec<u8>)> {
        if payload.len() < VIDEO_SUBHEADER_BYTES {
            return None;
        }
        let token = u16::from_be_bytes([payload[0], payload[1]]);
        // bytes 2..4 = flags (reserved, ignored)
        let pts = u64::from_be_bytes([
            payload[4],
            payload[5],
            payload[6],
            payload[7],
            payload[8],
            payload[9],
            payload[10],
            payload[11],
        ]);
        let nal = payload[VIDEO_SUBHEADER_BYTES..].to_vec();
        Some((token, pts, nal))
    }
}

/// CURSOR payload: the Source's pointer position over the streamed display — 8 bytes, two
/// big-endian f32 `(x, y)`, normalized 0..1, TOP-LEFT origin (matches winit's coordinate space, so
/// no Y-flip on the Display). Mirrors Swift `CursorPayload`. The Display renders a pointer overlay
/// at this position within the video rect; it does NOT move the local OS cursor.
pub struct CursorPayload;

impl CursorPayload {
    pub fn encode(x: f32, y: f32) -> Vec<u8> {
        let mut d = Vec::with_capacity(8);
        d.extend_from_slice(&x.to_be_bytes());
        d.extend_from_slice(&y.to_be_bytes());
        d
    }

    pub fn decode(payload: &[u8]) -> Option<(f32, f32)> {
        if payload.len() < 8 {
            return None;
        }
        let x = f32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
        let y = f32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
        Some((x, y))
    }
}

/// PING/PONG payload: an 8-byte big-endian monotonic nanosecond timestamp.
pub struct HeartbeatPayload;

impl HeartbeatPayload {
    pub fn encode(monotonic_nanos: u64) -> Vec<u8> {
        monotonic_nanos.to_be_bytes().to_vec()
    }

    pub fn decode(payload: &[u8]) -> Option<u64> {
        if payload.len() < 8 {
            return None;
        }
        Some(u64::from_be_bytes([
            payload[0], payload[1], payload[2], payload[3], payload[4], payload[5], payload[6],
            payload[7],
        ]))
    }
}

/// LTR_ACK payload: `count:u16` followed by `count` × `u16` acknowledged LTR tokens.
/// Reserved with LTR (not sent in v2), but kept for format completeness.
pub struct LtrAckPayload;

impl LtrAckPayload {
    pub fn encode(tokens: &[u16]) -> Vec<u8> {
        let mut d = Vec::with_capacity(2 + tokens.len() * 2);
        d.extend_from_slice(&(tokens.len() as u16).to_be_bytes());
        for t in tokens {
            d.extend_from_slice(&t.to_be_bytes());
        }
        d
    }

    pub fn decode(payload: &[u8]) -> Vec<u16> {
        if payload.len() < 2 {
            return Vec::new();
        }
        let count = u16::from_be_bytes([payload[0], payload[1]]) as usize;
        let mut tokens = Vec::with_capacity(count);
        let mut o = 2;
        let mut i = 0;
        while i < count && o + 2 <= payload.len() {
            tokens.push(u16::from_be_bytes([payload[o], payload[o + 1]]));
            o += 2;
            i += 1;
        }
        tokens
    }
}

#[cfg(test)]
mod cursor_tests {
    use super::CursorPayload;

    #[test]
    fn cursor_roundtrip_and_byte_layout() {
        let bytes = CursorPayload::encode(0.25, 0.75);
        assert_eq!(bytes.len(), 8);
        // BE f32 x then y.
        assert_eq!(&bytes[0..4], &0.25f32.to_be_bytes());
        assert_eq!(&bytes[4..8], &0.75f32.to_be_bytes());
        assert_eq!(CursorPayload::decode(&bytes), Some((0.25, 0.75)));
    }

    #[test]
    fn cursor_rejects_short_payload() {
        assert_eq!(CursorPayload::decode(&[0u8; 7]), None);
    }
}
