//! Blocking, framed read/write over a `rustls` TLS 1.3 stream. Establishes the handshake, derives
//! the [`TlsPeerInfo`] from the peer leaf (before any app data flows — mirrors `TCPTransport`'s
//! pre-`.ready` security context), then reads/writes 12-byte-header frames. Kept simple/blocking
//! for M1 (async can come later).

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

use rustls::{ClientConfig, ClientConnection, ServerConfig, ServerConnection, StreamOwned};

use sidewire_crypto::Identity;
use sidewire_proto::constants::{FRAME_HEADER_BYTES, MAX_FRAME_BYTES};
use sidewire_proto::Frame;

use crate::tls::{self, TlsError, TlsPeerInfo};

/// A coarse read/write timeout on the underlying socket, applied during the TLS handshake and the
/// blocking pre-CONFIG application handshake. Every read/write it guards carries a frame that arrives
/// within milliseconds in normal operation (TLS 1.3 is 1-RTT; the Source sends `PAIR_MSG` right after
/// TLS since the PIN is already entered), so a few seconds is ample — it only ever trips a genuinely
/// stalled/malicious peer. Kept modest (not 30 s) so that (a) a pre-auth slowloris is bounded and
/// (b) when the user closes the window while the worker is parked in a blocking handshake read, the
/// process finishes closing within this bound rather than lingering (the streaming phase already
/// honors the window stop flag within ~5 ms via the short `STREAM_READ_TIMEOUT`).
const SOCKET_IO_TIMEOUT: Duration = Duration::from_secs(5);

/// Errors establishing or using a wire.
#[derive(Debug, thiserror::Error)]
pub enum WireError {
    #[error("TLS error: {0}")]
    Tls(#[from] TlsError),
    #[error("rustls error: {0}")]
    Rustls(#[from] rustls::Error),
    #[error("io error: {0}")]
    Io(#[from] io::Error),
}

/// A readable/writable, `Send` TLS stream that also lets us retune the underlying socket's read
/// timeout — needed to switch from the coarse handshake timeout to the short streaming poll timeout
/// without unpacking the type-erased stream. Implemented for both concrete `StreamOwned` types via
/// their public `sock` field (the `TcpStream`).
trait WireStream: Read + Write + Send {
    fn set_read_timeout(&self, dur: Option<Duration>) -> io::Result<()>;
}

impl WireStream for StreamOwned<ServerConnection, TcpStream> {
    fn set_read_timeout(&self, dur: Option<Duration>) -> io::Result<()> {
        self.sock.set_read_timeout(dur)
    }
}

impl WireStream for StreamOwned<ClientConnection, TcpStream> {
    fn set_read_timeout(&self, dur: Option<Duration>) -> io::Result<()> {
        self.sock.set_read_timeout(dur)
    }
}

/// A framed TLS channel. Owns the `rustls` stream; the concrete server/client connection type is
/// erased behind a [`WireStream`] object once the handshake (which needs the concrete type) is done.
pub struct Wire {
    stream: Box<dyn WireStream>,
}

impl Wire {
    /// Establish the **server** (Display) side of a connection over an accepted `TcpStream`.
    pub fn accept(
        config: Arc<ServerConfig>,
        mut tcp: TcpStream,
        own: &Identity,
    ) -> Result<(Wire, TlsPeerInfo), WireError> {
        tcp.set_read_timeout(Some(SOCKET_IO_TIMEOUT))?;
        tcp.set_write_timeout(Some(SOCKET_IO_TIMEOUT))?;
        let mut conn = ServerConnection::new(config)?;
        // Drive the TLS 1.3 handshake to completion (blocking) so the peer leaf is available.
        loop {
            if !conn.is_handshaking() {
                break;
            }
            let (rd, wr) = conn.complete_io(&mut tcp)?;
            if conn.is_handshaking() && rd == 0 && wr == 0 {
                return Err(WireError::Io(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "TLS handshake did not complete",
                )));
            }
        }
        let peer = tls::peer_info(conn.peer_certificates(), own, true)?;
        let stream = StreamOwned::new(conn, tcp);
        Ok((
            Wire {
                stream: Box::new(stream),
            },
            peer,
        ))
    }

    /// Establish the **client** (Source) side of a connection by dialing.
    pub fn connect(
        config: Arc<ClientConfig>,
        mut tcp: TcpStream,
        own: &Identity,
    ) -> Result<(Wire, TlsPeerInfo), WireError> {
        tcp.set_read_timeout(Some(SOCKET_IO_TIMEOUT))?;
        tcp.set_write_timeout(Some(SOCKET_IO_TIMEOUT))?;
        let mut conn = ClientConnection::new(config, tls::dummy_server_name())?;
        loop {
            if !conn.is_handshaking() {
                break;
            }
            let (rd, wr) = conn.complete_io(&mut tcp)?;
            if conn.is_handshaking() && rd == 0 && wr == 0 {
                return Err(WireError::Io(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "TLS handshake did not complete",
                )));
            }
        }
        let peer = tls::peer_info(conn.peer_certificates(), own, false)?;
        let stream = StreamOwned::new(conn, tcp);
        Ok((
            Wire {
                stream: Box::new(stream),
            },
            peer,
        ))
    }

    /// Read exactly one frame (12-byte header + payload) from the stream. Blocks until a full frame
    /// arrives; returns an error on EOF, a transport failure, or an oversized length.
    pub fn read_frame(&mut self) -> io::Result<Frame> {
        let mut header = [0u8; FRAME_HEADER_BYTES];
        self.stream.read_exact(&mut header)?;
        let raw_type = header[0];
        let flags = header[1];
        // bytes 2,3 reserved (ignored)
        let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
        let seq = u32::from_be_bytes([header[8], header[9], header[10], header[11]]);
        if length > MAX_FRAME_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "frame length exceeds MAX_FRAME_BYTES",
            ));
        }
        // Read the payload incrementally, growing the buffer only as bytes actually arrive, rather
        // than pre-allocating the full declared length. A 12-byte header can legitimately claim up
        // to MAX_FRAME_BYTES (16 MiB); pre-zeroing that before a single payload byte lands is a
        // cheap 12 B → 16 MiB amplification. A peer that declares a large length but then stalls now
        // trips the socket timeout after allocating only what it actually sent.
        let mut payload = Vec::new();
        let mut remaining = length;
        let mut chunk = [0u8; 16 * 1024];
        while remaining > 0 {
            let want = remaining.min(chunk.len());
            let n = self.stream.read(&mut chunk[..want])?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed mid-frame payload",
                ));
            }
            payload.extend_from_slice(&chunk[..n]);
            remaining -= n;
        }
        Ok(Frame::new(raw_type, flags, seq, payload))
    }

    /// Encode and write one frame, flushing it to the peer.
    pub fn write_frame(
        &mut self,
        raw_type: u8,
        flags: u8,
        seq: u32,
        payload: &[u8],
    ) -> io::Result<()> {
        let bytes = sidewire_proto::encode_frame(raw_type, flags, seq, payload);
        self.stream.write_all(&bytes)?;
        self.stream.flush()
    }

    /// Retune the underlying socket's read timeout. The blocking handshake uses the coarse
    /// [`SOCKET_IO_TIMEOUT`]; the streaming loop drops it to a few milliseconds so a read that finds
    /// no frame returns promptly (as [`WouldBlock`]/[`TimedOut`]) instead of parking the single IO
    /// thread that must also send INPUT + heartbeat (docs/02 § Heartbeat; docs/03 § watchdog).
    ///
    /// [`WouldBlock`]: io::ErrorKind::WouldBlock
    /// [`TimedOut`]: io::ErrorKind::TimedOut
    pub fn set_read_timeout(&self, dur: Option<Duration>) -> io::Result<()> {
        self.stream.set_read_timeout(dur)
    }

    /// Read whatever plaintext is available right now into `buf`, returning the byte count. Unlike
    /// [`Wire::read_frame`] this does **not** block for a whole frame: with a short read timeout set
    /// (see [`Wire::set_read_timeout`]) a quiet link returns [`is_timeout`]`== true` and the caller
    /// treats it as "no frame yet". `Ok(0)` is a clean TLS EOF (peer sent close_notify). Feed the
    /// bytes to a [`sidewire_proto::FrameParser`], which buffers partial frames across calls.
    pub fn read_available(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.stream.read(buf)
    }
}

/// True if `err` is a read that timed out with no data (a short-timeout socket reports
/// `WouldBlock` on macOS/Linux, `TimedOut` on Windows) — i.e. "no frame yet", not a failure.
pub fn is_timeout(err: &io::Error) -> bool {
    matches!(
        err.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    )
}
