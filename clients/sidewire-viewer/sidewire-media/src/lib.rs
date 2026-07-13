//! Sidewire media decode (Phase 8, milestone M2) — H.264 / HEVC Annex-B software decode via
//! libavcodec (ffmpeg 7.x). **No windowing** here; the wgpu renderer lives in `sidewire-viewer`.
//!
//! The stream is clean Annex-B, in-band parameter sets at every IDR, no B-frames, joinable at any
//! keyframe (docs/04-media-pipeline.md). Each `VIDEO` payload is one self-contained access unit
//! (docs/02 § VIDEO); [`Decoder`] decodes them one at a time and carries the wire PTS through.
//!
//! Hardware decode (VideoToolbox / D3D11VA / VAAPI) is **deferred to M3+**; the software path is the
//! M2 baseline. The [`decoder::DecodeBackend`] trait is the seam a hardware backend slots into.

pub mod annexb;
pub mod decoder;

pub use annexb::{detect_codec, split_access_units, AccessUnit, Codec};
pub use decoder::{DecodeBackend, DecodeError, DecodedFrame, Decoder, PixelFormat, Plane};
