//! Frame framing: the 12-byte header + payload, an encoder, and an incremental parser.
//! Mirrors `Frame.swift`. Big-endian integers throughout (docs/02 § Transport framing).

use crate::constants::{FRAME_HEADER_BYTES, MAX_FRAME_BYTES};
use crate::message_type::MessageType;

/// A decoded wire frame: the raw type byte, flags, sequence, and payload bytes.
///
/// `raw_type` is kept as a `u8` (not [`MessageType`]) so that unknown/reserved types survive
/// parsing and can be skipped by the consumer — never treated as fatal (docs/02 reading rule).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub raw_type: u8,
    pub flags: u8,
    pub seq: u32,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(raw_type: u8, flags: u8, seq: u32, payload: Vec<u8>) -> Self {
        Self {
            raw_type,
            flags,
            seq,
            payload,
        }
    }

    /// The known message type, or `None` if the type byte is unknown/reserved.
    pub fn message_type(&self) -> Option<MessageType> {
        MessageType::from_u8(self.raw_type)
    }

    /// Encode this frame (12-byte header + payload) into a `Vec<u8>`, big-endian.
    ///
    /// # Panics
    /// Panics if the payload exceeds [`MAX_FRAME_BYTES`] — a programming error on the send path
    /// (mirrors the Swift `precondition`). Received oversized frames are rejected by the parser.
    pub fn encode(&self) -> Vec<u8> {
        encode(self.raw_type, self.flags, self.seq, &self.payload)
    }
}

/// Encode a frame header + payload. Layout: `type | flags | reserved:u16(=0) | length:u32 | seq:u32`.
pub fn encode(raw_type: u8, flags: u8, seq: u32, payload: &[u8]) -> Vec<u8> {
    assert!(
        payload.len() <= MAX_FRAME_BYTES,
        "payload exceeds MAX_FRAME_BYTES"
    );
    let mut out = Vec::with_capacity(FRAME_HEADER_BYTES + payload.len());
    out.push(raw_type);
    out.push(flags);
    out.push(0); // reserved hi (MUST be 0 on send)
    out.push(0); // reserved lo
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&seq.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Convenience: encode a frame identified by a known [`MessageType`].
pub fn encode_typed(msg_type: MessageType, flags: u8, seq: u32, payload: &[u8]) -> Vec<u8> {
    encode(msg_type.as_u8(), flags, seq, payload)
}

/// A frame-parsing error. A `FrameTooLarge` means the stream is unrecoverable and the connection
/// must be dropped (docs/02: reject `length > MAX_FRAME_BYTES`).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ParseError {
    #[error("frame declared payload of {0} bytes, exceeding MAX_FRAME_BYTES")]
    FrameTooLarge(u32),
}

/// Incremental, allocation-safe frame parser. Feed it arbitrary byte chunks as they arrive from
/// the transport; it yields complete frames and buffers partials. Unknown message types are
/// returned like any other frame (forward compatibility). Mirrors `FrameParser`.
#[derive(Default)]
pub struct FrameParser {
    buffer: Vec<u8>,
    /// Offset of the first unconsumed byte. Frames advance this rather than draining the front, so
    /// a burst of N small frames in one `append` costs O(total) rather than O(N × remaining) — a
    /// front-drain per frame memmoves the whole tail each time and burned the single IO thread
    /// under a flood of minimal frames. The consumed prefix is reclaimed once per `append`.
    start: usize,
}

impl FrameParser {
    pub fn new() -> Self {
        Self {
            buffer: Vec::new(),
            start: 0,
        }
    }

    /// Append incoming bytes and return all frames now fully available.
    /// Returns [`ParseError::FrameTooLarge`] on a corrupt/hostile length (caller drops the link).
    pub fn append(&mut self, data: &[u8]) -> Result<Vec<Frame>, ParseError> {
        self.buffer.extend_from_slice(data);
        let mut frames = Vec::new();
        while let Some(frame) = self.parse_one()? {
            frames.push(frame);
        }
        // Reclaim consumed bytes exactly once — a single memmove regardless of how many frames
        // were parsed. Skipped when nothing was consumed (a partial frame still buffering).
        if self.start > 0 {
            self.buffer.drain(..self.start);
            self.start = 0;
        }
        Ok(frames)
    }

    /// Bytes buffered but not yet forming a complete frame (for diagnostics/tests).
    pub fn pending_byte_count(&self) -> usize {
        self.buffer.len() - self.start
    }

    fn parse_one(&mut self) -> Result<Option<Frame>, ParseError> {
        let buf = &self.buffer[self.start..];
        if buf.len() < FRAME_HEADER_BYTES {
            return Ok(None);
        }
        let raw_type = buf[0];
        let flags = buf[1];
        // bytes 2,3 reserved (ignored)
        let length = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let seq = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]);

        if length as usize > MAX_FRAME_BYTES {
            return Err(ParseError::FrameTooLarge(length));
        }

        let total = FRAME_HEADER_BYTES + length as usize;
        if buf.len() < total {
            return Ok(None);
        }

        let payload = buf[FRAME_HEADER_BYTES..total].to_vec();
        self.start += total; // consumed; the prefix is reclaimed at the end of append()
        Ok(Some(Frame::new(raw_type, flags, seq, payload)))
    }
}

#[cfg(test)]
mod parser_burst_tests {
    use super::*;
    use crate::MessageType;

    #[test]
    fn burst_of_minimal_frames_parses_all_and_leaves_no_pending() {
        // A flood of zero-payload frames in one append — the O(n^2) path this rewrite fixes.
        let mut chunk = Vec::new();
        for seq in 0..1000u32 {
            chunk.extend_from_slice(&encode_typed(MessageType::Ping, 0, seq, &[]));
        }
        let mut parser = FrameParser::new();
        let frames = parser.append(&chunk).unwrap();
        assert_eq!(frames.len(), 1000);
        assert_eq!(frames[0].seq, 0);
        assert_eq!(frames[999].seq, 999);
        assert_eq!(parser.pending_byte_count(), 0);
    }

    #[test]
    fn partial_tail_after_burst_is_preserved_across_appends() {
        let whole = encode_typed(MessageType::Ping, 0, 7, &[]);
        let (head, tail) = whole.split_at(5);
        let mut parser = FrameParser::new();
        assert!(parser.append(head).unwrap().is_empty());
        assert_eq!(parser.pending_byte_count(), 5);
        let frames = parser.append(tail).unwrap();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].seq, 7);
        assert_eq!(parser.pending_byte_count(), 0);
    }
}
