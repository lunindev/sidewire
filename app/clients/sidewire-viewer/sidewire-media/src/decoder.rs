//! H.264 / HEVC Annex-B decode via libavcodec (ffmpeg 7.x), fed one access unit at a time.
//!
//! The Sidewire stream is clean Annex-B with in-band parameter sets at every IDR and **no B-frames**
//! (docs/04-media-pipeline.md), so each `VIDEO` payload's NAL data is a self-contained access unit
//! that goes straight to libavcodec — **no demuxer / format context**. Output order equals input
//! order (no reordering), which lets us carry the **wire PTS** (docs/02 § VIDEO subheader) straight
//! through with a FIFO rather than trusting ffmpeg's guessed timestamps.
//!
//! ## Backend seam
//! [`Decoder`] owns a [`DecodeBackend`]. M2 ships the software [`SoftwareBackend`] (robust,
//! cross-platform). A hardware backend (VideoToolbox / D3D11VA / VAAPI) can implement the same trait
//! later — see the `TODO(M3+)` in [`SoftwareBackend`] — without changing the keyframe-gate /
//! rebuild-on-error logic in [`Decoder`].

use ffmpeg_the_third as ffmpeg;

pub use crate::annexb::Codec;

/// Decode errors.
#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    #[error("ffmpeg error: {0}")]
    Ffmpeg(#[from] ffmpeg::Error),
    #[error("no decoder available for codec {0:?}")]
    NoDecoder(Codec),
    #[error("decoder produced an unsupported pixel format: {0:?}")]
    UnsupportedFormat(ffmpeg::format::Pixel),
}

/// A decoded frame's pixel layout. Software decode yields [`PixelFormat::Yuv420p`]; a future
/// hardware path commonly yields [`PixelFormat::Nv12`]. The renderer supports both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelFormat {
    /// Planar Y, U, V — three planes (`R8` each on the GPU).
    Yuv420p,
    /// Planar Y + interleaved UV — two planes (`R8` + `RG8` on the GPU).
    Nv12,
}

impl PixelFormat {
    fn from_ffmpeg(px: ffmpeg::format::Pixel) -> Option<PixelFormat> {
        match px {
            ffmpeg::format::Pixel::YUV420P => Some(PixelFormat::Yuv420p),
            ffmpeg::format::Pixel::NV12 => Some(PixelFormat::Nv12),
            _ => None,
        }
    }

    /// Number of image planes for this format.
    pub fn plane_count(self) -> usize {
        match self {
            PixelFormat::Yuv420p => 3,
            PixelFormat::Nv12 => 2,
        }
    }
}

/// One image plane: tightly-referenced rows of `stride` bytes, `height` rows, with `width` valid
/// samples per row (`stride >= width * bytes_per_sample`; the tail is alignment padding).
#[derive(Debug, Clone)]
pub struct Plane {
    /// Row-major sample bytes; row `r` starts at `r * stride`. Length is `stride * height`.
    pub data: Vec<u8>,
    /// Row pitch in **bytes** (may exceed the visible width due to ffmpeg alignment).
    pub stride: usize,
    /// Visible samples per row (Y = frame width; chroma = ceil(width/2), etc.).
    pub width: usize,
    /// Number of rows.
    pub height: usize,
}

/// A decoded frame handed to the renderer. Carries the **wire PTS** (docs/02 § VIDEO), not ffmpeg's.
#[derive(Debug, Clone)]
pub struct DecodedFrame {
    pub width: u32,
    pub height: u32,
    pub format: PixelFormat,
    /// Planes in the format's canonical order (Y,U,V for 420p; Y,UV for NV12).
    pub planes: Vec<Plane>,
    /// Capture presentation timestamp in nanoseconds, on the source's arbitrary monotonic epoch
    /// (docs/02). `0` = unspecified. Carried through from the `VIDEO` subheader, unchanged.
    pub pts_nanos: u64,
}

/// A decode backend: turn Annex-B access units into [`DecodedFrame`]s. The seam that lets a hardware
/// decoder replace software decode later without changing [`Decoder`].
pub trait DecodeBackend {
    /// Decode one Annex-B access unit stamped with the wire `pts_nanos`. Returns 0+ frames — an AU
    /// that yields no frame yet (decoder buffering) returns an empty vec, not an error.
    fn decode(&mut self, au: &[u8], pts_nanos: u64) -> Result<Vec<DecodedFrame>, DecodeError>;

    /// Discard and rebuild all decoder state (after a hard error). The next AU must be a keyframe.
    fn rebuild(&mut self) -> Result<(), DecodeError>;
}

/// Software (libavcodec) decode backend — the M2 baseline.
pub struct SoftwareBackend {
    codec: Codec,
    decoder: ffmpeg::decoder::Video,
}

impl SoftwareBackend {
    /// Build a software decoder for `codec`.
    pub fn new(codec: Codec) -> Result<SoftwareBackend, DecodeError> {
        // Idempotent; safe to call once per decoder. Initializes libavcodec.
        ffmpeg::init()?;
        let decoder = Self::open(codec)?;
        Ok(SoftwareBackend { codec, decoder })
    }

    fn open(codec: Codec) -> Result<ffmpeg::decoder::Video, DecodeError> {
        let id = match codec {
            Codec::H264 => ffmpeg::codec::Id::H264,
            Codec::Hevc => ffmpeg::codec::Id::HEVC,
        };
        // TODO(M3+): hardware decode. Select a hw-accelerated decoder here (VideoToolbox on macOS,
        // D3D11VA on Windows, VAAPI on Linux) via `ffmpeg::codec::decoder::find_by_name` +
        // `av_hwdevice_ctx_create`, falling back to this software path (a moonlight-qt-style ladder).
        // The public `DecodeBackend` trait is the seam; nothing above this line needs to change.
        let ff_codec = ffmpeg::codec::decoder::find(id).ok_or(DecodeError::NoDecoder(codec))?;
        let context = ffmpeg::codec::context::Context::new_with_codec(ff_codec);
        Ok(context.decoder().video()?)
    }

    /// Drain all frames currently available from the decoder into `out`. Each frame carries the
    /// **wire PTS** we stamped on its source packet (libavcodec copies `pkt->pts` → `frame->pts`).
    fn drain(&mut self, out: &mut Vec<DecodedFrame>) -> Result<(), DecodeError> {
        let mut frame = ffmpeg::frame::Video::empty();
        // `receive_frame` returns Err(EAGAIN) when nothing is ready — the loop ends cleanly then.
        while self.decoder.receive_frame(&mut frame).is_ok() {
            // The PTS we set on the packet (`decode`) comes back on the frame. `unwrap_or(0)` maps
            // an absent/NOPTS timestamp to "unspecified" (docs/02 § VIDEO).
            let pts = frame.pts().map(|p| p as u64).unwrap_or(0);
            out.push(convert_frame(&frame, pts)?);
        }
        Ok(())
    }
}

impl DecodeBackend for SoftwareBackend {
    fn decode(&mut self, au: &[u8], pts_nanos: u64) -> Result<Vec<DecodedFrame>, DecodeError> {
        let mut packet = ffmpeg::packet::Packet::copy(au);
        // Stamp the wire PTS on the packet; libavcodec carries it through to the decoded frame. With
        // no B-frames output order equals input order, so this is exact — and, unlike a side FIFO
        // keyed on packet count, it stays correct even if the decoder ever emits zero or several
        // frames for one packet (e.g. a dropped frame no longer permanently shifts every later PTS).
        packet.set_pts(Some(pts_nanos as i64));
        self.decoder.send_packet(&packet)?;
        let mut out = Vec::new();
        self.drain(&mut out)?;
        Ok(out)
    }

    fn rebuild(&mut self) -> Result<(), DecodeError> {
        self.decoder = Self::open(self.codec)?;
        Ok(())
    }
}

/// Copy a decoded ffmpeg frame into an owned [`DecodedFrame`], carrying `pts_nanos` through.
fn convert_frame(
    frame: &ffmpeg::frame::Video,
    pts_nanos: u64,
) -> Result<DecodedFrame, DecodeError> {
    let px = frame.format();
    let format = PixelFormat::from_ffmpeg(px).ok_or(DecodeError::UnsupportedFormat(px))?;
    let width = frame.width();
    let height = frame.height();

    // Per-plane logical dimensions. Luma is full size; chroma is subsampled by 2 in both axes
    // (4:2:0). NV12 interleaves U and V into one plane of ceil(w/2) *samples* (2 bytes each).
    let planes: Vec<Plane> = (0..format.plane_count())
        .map(|i| {
            let stride = frame.stride(i);
            let (pw, ph) = plane_dims(format, i, width, height);
            let data = frame.data(i).to_vec();
            Plane {
                data,
                stride,
                width: pw,
                height: ph,
            }
        })
        .collect();

    Ok(DecodedFrame {
        width,
        height,
        format,
        planes,
        pts_nanos,
    })
}

/// Logical `(width, height)` in *samples* for plane `i` of a 4:2:0 `format`.
fn plane_dims(format: PixelFormat, i: usize, width: u32, height: u32) -> (usize, usize) {
    let w = width as usize;
    let h = height as usize;
    let cw = w.div_ceil(2);
    let ch = h.div_ceil(2);
    match (format, i) {
        (_, 0) => (w, h),                      // Y
        (PixelFormat::Yuv420p, _) => (cw, ch), // U or V
        (PixelFormat::Nv12, _) => (cw, ch),    // interleaved UV: cw samples (RG8) × ch
    }
}

/// A codec-typed access-unit decoder with a keyframe gate and rebuild-on-error recovery.
///
/// Feeds AUs to a [`DecodeBackend`]. Until the first keyframe arrives, non-keyframe AUs are dropped
/// (you cannot start mid-GOP). On a hard backend error the decoder rebuilds and re-arms the gate, so
/// decoding resumes at the next keyframe rather than emitting garbage or wedging.
pub struct Decoder {
    backend: Box<dyn DecodeBackend>,
    /// True once a keyframe has been accepted; false at start and after a rebuild.
    started: bool,
}

impl Decoder {
    /// Build a software decoder for `codec` (the M2 default backend).
    pub fn new(codec: Codec) -> Result<Decoder, DecodeError> {
        Ok(Decoder::with_backend(Box::new(SoftwareBackend::new(
            codec,
        )?)))
    }

    /// Build a decoder over an explicit backend (e.g. a future hardware backend, or a test double).
    pub fn with_backend(backend: Box<dyn DecodeBackend>) -> Decoder {
        Decoder {
            backend,
            started: false,
        }
    }

    /// Feed one Annex-B access unit (a `VIDEO` payload's NAL data) with its wire PTS and keyframe
    /// flag (docs/02 § VIDEO). Returns the frames it produced (usually one; possibly zero while the
    /// decoder buffers, or if a pre-keyframe AU was dropped).
    ///
    /// On a hard decode error the backend is rebuilt and an empty vec is returned; the caller should
    /// request an IDR (docs/02 § REQUEST_IDR) so decoding can resume at the next keyframe.
    pub fn decode_access_unit(
        &mut self,
        au: &[u8],
        keyframe: bool,
        pts_nanos: u64,
    ) -> Result<Vec<DecodedFrame>, DecodeError> {
        if !self.started {
            if !keyframe {
                return Ok(Vec::new()); // cannot join mid-GOP; wait for the first keyframe
            }
            self.started = true;
        }
        match self.backend.decode(au, pts_nanos) {
            Ok(frames) => Ok(frames),
            Err(_hard_error) => {
                // Rebuild and re-arm the keyframe gate. Swallow a rebuild failure into the same
                // "need a keyframe" state — the next successful open + keyframe recovers.
                self.started = false;
                let _ = self.backend.rebuild();
                Ok(Vec::new())
            }
        }
    }

    /// Whether the decoder has accepted a keyframe and is producing frames.
    pub fn is_started(&self) -> bool {
        self.started
    }
}
