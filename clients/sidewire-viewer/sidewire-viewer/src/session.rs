//! The pairing + HELLO state machine, driven over the blocking [`Wire`]. A faithful port of the
//! relevant paths of `Session.swift`, implementing **both** roles: the Display responder (the
//! product) and the Source initiator (the loopback test peer).
//!
//! Connection lifecycle (docs/02 § Handshake): TCP → TLS 1.3 → [CPace if not already paired] →
//! HELLO/HELLO_ACK → (Display sends DISPLAY_INFO right after its HELLO_ACK) → Source sends CONFIG →
//! streaming reached. The **Source leads**; the Display reacts to whatever the Source leads with
//! (never sends first). For M1 the state machine runs until CONFIG is reached (or the session
//! closes); heartbeat/streaming arrive in later milestones.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use sidewire_proto::{
    video_flags, Config, DisplayInfo, FrameParser, HeartbeatPayload, Hello, InputEventRecord,
    MessageType, ReasonMessage, Role, VideoPayload,
};

use crate::rate_limiter::PairingRateLimiter;
use crate::trust_store::{TrustStoring, TrustedPeer};
use crate::wire::{self, Wire};
use sidewire_crypto::cpace;

/// Injectable heartbeat/watchdog timing (docs/02 § Heartbeat, docs/03 § watchdog). The defaults are
/// the normative 500 ms PING cadence / 2500 ms silence budget; tests inject much shorter values so
/// they exercise the timeout/keep-alive paths without waiting real seconds.
#[derive(Debug, Clone, Copy)]
pub struct HeartbeatConfig {
    /// Transmit a `PING` at least this often (docs/02: `HEARTBEAT_INTERVAL`).
    pub interval: Duration,
    /// Declare the peer dead — close with reason `"timeout"` — after this much inbound silence
    /// (docs/02: `HEARTBEAT_TIMEOUT`). **Any** inbound frame resets the watchdog.
    pub timeout: Duration,
}

impl Default for HeartbeatConfig {
    fn default() -> Self {
        Self {
            interval: Duration::from_secs_f64(sidewire_proto::HEARTBEAT_INTERVAL_SECS),
            timeout: Duration::from_secs_f64(sidewire_proto::HEARTBEAT_TIMEOUT_SECS),
        }
    }
}

/// Short socket read timeout used during streaming so an idle read returns promptly and the single
/// IO thread can service the INPUT channel + heartbeat between reads (see [`Session::run_streaming`]).
const STREAM_READ_TIMEOUT: Duration = Duration::from_millis(5);

/// Buffer size for one incremental streaming read. Large enough to swallow a decent chunk of a
/// VIDEO frame per syscall, small enough to stay off the stack cheaply.
const STREAM_READ_BUF: usize = 64 * 1024;

/// A process-monotonic nanosecond clock for `PING` payloads. The value is only ever echoed back in a
/// `PONG` and diffed on the originator's own clock (docs/02 § PING/PONG), so the epoch is arbitrary.
fn monotonic_nanos() -> u64 {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    EPOCH.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

/// Everything the Session needs to run (or skip) CPace before HELLO. Mirrors `PairingConfig`.
pub struct PairingConfig {
    /// The 6-digit PIN (Source: what the user typed; Display: what this device is showing).
    pub pin: String,
    /// This device's trust store (to check for an existing pin and to pin on success).
    pub trust_store: Arc<dyn TrustStoring>,
    /// Display side only: rate-limits online PIN guessing. `None` on the Source.
    pub rate_limiter: Option<Arc<PairingRateLimiter>>,
}

impl PairingConfig {
    pub fn new(
        pin: impl Into<String>,
        trust_store: Arc<dyn TrustStoring>,
        rate_limiter: Option<Arc<PairingRateLimiter>>,
    ) -> Self {
        Self {
            pin: pin.into(),
            trust_store,
            rate_limiter,
        }
    }
}

/// One access unit to transmit as a `VIDEO` frame via [`Session::run_sending_video`] (the loopback
/// Source peer). `nal` is the raw Annex-B AU; `keyframe` sets the FRAME flags keyframe bit.
#[derive(Debug, Clone)]
pub struct OutgoingVideo {
    pub nal: Vec<u8>,
    pub keyframe: bool,
    pub pts_nanos: u64,
}

/// **Test/loopback helper.** How the Source peer should behave in the streaming phase after CONFIG,
/// driving [`Session::run_source_stream`]. Lets a test exercise the Display's heartbeat/watchdog and
/// input-send paths without a live Mac.
#[derive(Debug, Clone)]
pub struct SourceStreamPlan {
    /// Short incremental read timeout (mirrors the Display's streaming reader).
    pub read_timeout: Duration,
    /// Send a `PING` every `ping_interval` (to keep the Display's watchdog fed).
    pub send_ping: bool,
    pub ping_interval: Duration,
    /// Payload for each sent `PING`. `None` uses the monotonic-clock value (production behavior);
    /// tests set a fixed 8-byte value to assert the Display echoes it back **exactly** in its `PONG`
    /// (docs/02 § PING/PONG).
    pub ping_payload: Option<[u8; 8]>,
    /// Reply `PONG` to inbound `PING`s (also keeps the Display alive).
    pub echo_pong: bool,
    /// Hard cap on time spent streaming before closing with `BYE("user")`.
    pub max_duration: Duration,
    /// Stop (and `BYE("user")`) as soon as this many INPUT records have been collected.
    pub stop_after_inputs: Option<usize>,
}

impl Default for SourceStreamPlan {
    fn default() -> Self {
        Self {
            read_timeout: Duration::from_millis(5),
            send_ping: false,
            ping_interval: Duration::from_millis(20),
            ping_payload: None,
            echo_pong: false,
            max_duration: Duration::from_secs(2),
            stop_after_inputs: None,
        }
    }
}

/// **Test/loopback helper.** What the Source peer observed while streaming (see [`SourceStreamPlan`]).
pub struct SourceStreamResult {
    pub outcome: SessionOutcome,
    /// INPUT records received from the Display, decoded from the 32-byte wire form.
    pub inputs: Vec<InputEventRecord>,
    /// Count of inbound `PING`s from the Display.
    pub pings_received: usize,
    /// Count of inbound `PONG`s from the Display (echoes of this peer's `PING`s).
    pub pongs_received: usize,
    /// Payload of the most recent `PONG` received from the Display — the Display must echo the exact
    /// bytes of the `PING` we sent (docs/02 § PING/PONG). `None` if no `PONG` arrived.
    pub last_pong_payload: Option<Vec<u8>>,
}

/// Direction of a recorded wire event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dir {
    Sent,
    Recv,
}

/// One recorded frame (direction + raw type) — the ordered log the tests assert against (e.g. the
/// Tb-withhold ordering invariant).
#[derive(Debug, Clone, Copy)]
pub struct WireEvent {
    pub dir: Dir,
    pub raw_type: u8,
}

/// The result of driving a session to completion.
pub struct SessionOutcome {
    /// The negotiated config, if streaming (CONFIG) was reached. On the Source this is the config it
    /// computed and sent; on the Display it is the config it received.
    pub config: Option<Config>,
    /// The close reason, if the session closed before/instead of reaching CONFIG.
    pub close_reason: Option<String>,
    /// The ordered log of frames sent/received (for test assertions).
    pub events: Vec<WireEvent>,
}

impl SessionOutcome {
    /// Count of frames of `msg_type` sent in this session.
    pub fn sent_count(&self, msg_type: MessageType) -> usize {
        self.count(Dir::Sent, msg_type)
    }

    /// Count of frames of `msg_type` received in this session.
    pub fn recv_count(&self, msg_type: MessageType) -> usize {
        self.count(Dir::Recv, msg_type)
    }

    fn count(&self, dir: Dir, msg_type: MessageType) -> usize {
        self.events
            .iter()
            .filter(|e| e.dir == dir && e.raw_type == msg_type.as_u8())
            .count()
    }

    /// True if a frame of `msg_type` was **sent** before any frame of `msg_type` was **received**
    /// (used to check the Display's Tb-withhold ordering: it must NOT send PAIR_CONFIRM until after
    /// it receives the Source's PAIR_CONFIRM).
    pub fn sent_before_received(&self, msg_type: MessageType) -> bool {
        let first_sent = self
            .events
            .iter()
            .position(|e| e.dir == Dir::Sent && e.raw_type == msg_type.as_u8());
        let first_recv = self
            .events
            .iter()
            .position(|e| e.dir == Dir::Recv && e.raw_type == msg_type.as_u8());
        match (first_sent, first_recv) {
            (Some(s), Some(r)) => s < r,
            (Some(_), None) => true,
            _ => false,
        }
    }
}

/// Drives one connection through pairing + HELLO to CONFIG. Symmetric across roles.
pub struct Session {
    role: Role,
    local_hello: Hello,
    /// Display side only: the native panel description sent after HELLO_ACK.
    display_info: Option<DisplayInfo>,
    wire: Wire,
    tls: crate::tls::TlsPeerInfo,
    pairing: PairingConfig,

    seq: u32,

    // Pairing (CPace) state.
    cpace_scalar: Option<[u8; 32]>,
    cpace_own_share: Option<[u8; 32]>,
    cpace_mac_key: Option<Vec<u8>>,
    cpace_expected_peer_tag: Option<Vec<u8>>,
    app_handshake_started: bool,
    awaiting_peer_share: bool,
    pairing_replied: bool,

    // Handshake state.
    peer_hello: Option<Hello>,
    peer_display_info: Option<DisplayInfo>,
    config_sent: bool,
    ready: bool,
    negotiated_config: Option<Config>,

    closed: bool,
    close_reason: Option<String>,
    events: Vec<WireEvent>,
    /// Whether to append to [`Session::events`]. On during the (short) handshake so tests can assert
    /// frame ordering; turned **off** once streaming begins so a long session's hot-path frames
    /// (VIDEO/INPUT/PING/PONG) don't grow the log without bound.
    record_events: bool,
}

impl Session {
    pub fn new(
        role: Role,
        local_hello: Hello,
        display_info: Option<DisplayInfo>,
        wire: Wire,
        tls: crate::tls::TlsPeerInfo,
        pairing: PairingConfig,
    ) -> Self {
        Self {
            role,
            local_hello,
            display_info,
            wire,
            tls,
            pairing,
            seq: 0,
            cpace_scalar: None,
            cpace_own_share: None,
            cpace_mac_key: None,
            cpace_expected_peer_tag: None,
            app_handshake_started: false,
            awaiting_peer_share: false,
            pairing_replied: false,
            peer_hello: None,
            peer_display_info: None,
            config_sent: false,
            ready: false,
            negotiated_config: None,
            closed: false,
            close_reason: None,
            events: Vec::new(),
            record_events: true,
        }
    }

    /// Drive the session (blocking) until it reaches CONFIG or closes. Consumes `self`.
    ///
    /// This is the M1 handshake-only path: it stops the moment streaming (CONFIG) is reached. For
    /// the M2 Display streaming loop (decode incoming VIDEO), use [`Session::run_streaming`]; the
    /// two share the same handshake internals so the M1 tests are unaffected.
    pub fn run(mut self) -> SessionOutcome {
        self.begin_pairing_or_handshake();
        while !self.ready && !self.closed {
            match self.wire.read_frame() {
                Ok(frame) => {
                    self.record_recv(frame.raw_type);
                    self.handle(frame);
                }
                Err(_) => {
                    self.mark_transport_closed();
                    break;
                }
            }
        }
        self.into_outcome()
    }

    /// Drive the **Display** session through pairing + HELLO to CONFIG and then into the streaming
    /// loop that runs all three streaming duties on one TLS connection, single-threaded (no
    /// concurrent-write race): it **receives** VIDEO (each `VIDEO` payload parsed per docs/02 § VIDEO
    /// and handed to `on_video(nal, keyframe, pts_nanos)` — `keyframe` = the FRAME `flags` keyframe
    /// bit `0x01`, `pts_nanos` = the subheader PTS), **sends** INPUT drained from `input_rx`, and
    /// runs the **heartbeat/watchdog** (docs/02 § Heartbeat, docs/03 § watchdog):
    ///
    /// * a `PING` is sent every `heartbeat.interval`;
    /// * **any** inbound frame resets the watchdog; inbound silence beyond `heartbeat.timeout` closes
    ///   the session with reason `"timeout"`;
    /// * an inbound `PING` is answered with `PONG` (exact 8-byte echo); `BYE` closes with its reason.
    ///
    /// `stop` is the window's stop flag (the one behind `FrameProducer::should_stop`): when the user
    /// closes the window it is set, and the streaming loop notices it, sends `BYE("user")`, and
    /// unwinds promptly — so the Source sees a clean goodbye instead of waiting out its 2.5 s
    /// watchdog. Tests that don't model a window pass a never-set flag.
    ///
    /// The handshake phase uses the blocking [`Wire::read_frame`]; only the streaming phase switches
    /// to the short-timeout incremental read. A window close during the handshake is honored within
    /// the wire's socket timeout (a blocked read wakes on it, then the `stop` check breaks) — no BYE
    /// is sent then, which is fine: the peer is still pre-stream. Returns when the peer/watchdog
    /// closes. Consumes `self`.
    pub fn run_streaming<F>(
        mut self,
        input_rx: &Receiver<InputEventRecord>,
        stop: &AtomicBool,
        heartbeat: HeartbeatConfig,
        mut on_video: F,
    ) -> SessionOutcome
    where
        F: FnMut(&[u8], bool, u64),
    {
        self.begin_pairing_or_handshake();
        // Phase 1 — blocking handshake to CONFIG (milliseconds under the socket timeout in normal
        // operation). The fine-grained ≤2.5 s heartbeat/watchdog governs only the streaming phase
        // below. Poll the window `stop` flag each iteration so a close during pairing unwinds within
        // the socket timeout instead of parking until the peer sends its next frame.
        while !self.ready && !self.closed {
            if stop.load(Ordering::Relaxed) {
                break; // window closed mid-handshake — bare close (pre-stream, no BYE expected)
            }
            match self.wire.read_frame() {
                Ok(frame) => {
                    self.record_recv(frame.raw_type);
                    self.handle(frame);
                }
                Err(_) => {
                    self.mark_transport_closed();
                    break;
                }
            }
        }
        if self.ready && !self.closed {
            self.stream_loop(input_rx, stop, heartbeat, &mut on_video);
        }
        self.into_outcome()
    }

    /// The post-CONFIG streaming loop: send INPUT + heartbeat, receive VIDEO/PING/BYE, run the
    /// watchdog. Single IO thread, short-timeout reads so no duty starves another. Also polls the
    /// window `stop` flag so a window close unwinds the loop with `BYE("user")`.
    fn stream_loop<F>(
        &mut self,
        input_rx: &Receiver<InputEventRecord>,
        stop: &AtomicBool,
        heartbeat: HeartbeatConfig,
        on_video: &mut F,
    ) where
        F: FnMut(&[u8], bool, u64),
    {
        // A live session runs for hours at 60 fps — stop growing the event log now (it is a
        // short-handshake test aid, not a hot-path buffer).
        self.record_events = false;
        let _ = self.wire.set_read_timeout(Some(STREAM_READ_TIMEOUT));

        let mut parser = FrameParser::new();
        let mut buf = [0u8; STREAM_READ_BUF];
        let now = Instant::now();
        let mut last_ping = now;
        let mut last_inbound = now;

        while !self.closed {
            // (0) The user closed the window: say a proper goodbye so the Source doesn't sit on its
            // 2.5 s watchdog, then unwind. Checked first so a close is honored within one loop tick.
            if stop.load(Ordering::Relaxed) {
                self.close_sending_bye("user");
                break;
            }

            // (a) Drain queued INPUT events and send each as an INPUT frame (docs/02 § INPUT). A
            // closed channel (window/input source gone) just ends the drain; the video link stays up
            // until the peer or the watchdog ends it.
            while let Ok(rec) = input_rx.try_recv() {
                self.send(MessageType::Input, 0, &rec.encode());
                if self.closed {
                    break;
                }
            }
            if self.closed {
                break;
            }

            let now = Instant::now();
            // (b) Keep the link warm: PING on cadence (docs/02: every HEARTBEAT_INTERVAL).
            if now.duration_since(last_ping) >= heartbeat.interval {
                self.send(
                    MessageType::Ping,
                    0,
                    &HeartbeatPayload::encode(monotonic_nanos()),
                );
                last_ping = now;
            }
            if self.closed {
                break;
            }
            // (c) Watchdog: inbound silence past the budget ⇒ peer is dead (docs/02 § Heartbeat).
            if now.duration_since(last_inbound) > heartbeat.timeout {
                self.close_sending_bye("timeout");
                break;
            }

            // (d) Read whatever plaintext is available; feed the incremental parser.
            match self.wire.read_available(&mut buf) {
                Ok(0) => {
                    self.mark_transport_closed(); // clean TLS EOF
                    break;
                }
                Ok(n) => match parser.append(&buf[..n]) {
                    Ok(frames) => {
                        for frame in frames {
                            last_inbound = Instant::now(); // ANY inbound frame resets the watchdog
                            self.record_recv(frame.raw_type);
                            self.handle_stream_frame(frame, on_video);
                            if self.closed {
                                break;
                            }
                        }
                    }
                    // A corrupt/oversized declared length is an unrecoverable framing error.
                    Err(_) => {
                        self.close_sending_bye("transport");
                        break;
                    }
                },
                Err(ref e) if wire::is_timeout(e) => { /* no frame yet — loop and service duties */
                }
                Err(_) => {
                    self.mark_transport_closed();
                    break;
                }
            }
        }
    }

    /// **Test/loopback helper (Source peer).** Drive the Source handshake to CONFIG, then send each
    /// access unit as a `VIDEO` frame — keyframe bit in the FRAME flags, PTS in the subheader
    /// (docs/02 § VIDEO) — and finally close with `BYE("user")`. The production Source is the Mac;
    /// this exists so the loopback video test can feed a fixture clip through a real TLS session.
    pub fn run_sending_video(mut self, frames: &[OutgoingVideo]) -> SessionOutcome {
        self.begin_pairing_or_handshake();
        while !self.ready && !self.closed {
            match self.wire.read_frame() {
                Ok(frame) => {
                    self.record_recv(frame.raw_type);
                    self.handle(frame);
                }
                Err(_) => {
                    self.mark_transport_closed();
                    break;
                }
            }
        }
        if self.ready && !self.closed {
            for f in frames {
                let flags = if f.keyframe { video_flags::KEYFRAME } else { 0 };
                let payload = VideoPayload::encode(0, f.pts_nanos, &f.nal);
                self.send(MessageType::Video, flags, &payload);
                if self.closed {
                    break;
                }
            }
            if !self.closed {
                self.close_sending_bye("user");
            }
        }
        self.into_outcome()
    }

    /// **Test/loopback helper (Source peer).** Drive the Source handshake to CONFIG, then run a
    /// streaming loop per `plan`: optionally send periodic `PING`, optionally echo `PONG`, collect
    /// inbound INPUT records, and count inbound `PING`/`PONG`, until the peer closes / `max_duration`
    /// elapses / `stop_after_inputs` is reached — then close with `BYE("user")`. Mirrors the Display
    /// stream loop's shape so a test can exercise the heartbeat + input-send paths without a Mac.
    pub fn run_source_stream(mut self, plan: SourceStreamPlan) -> SourceStreamResult {
        self.begin_pairing_or_handshake();
        while !self.ready && !self.closed {
            match self.wire.read_frame() {
                Ok(frame) => {
                    self.record_recv(frame.raw_type);
                    self.handle(frame);
                }
                Err(_) => {
                    self.mark_transport_closed();
                    break;
                }
            }
        }

        let mut inputs: Vec<InputEventRecord> = Vec::new();
        let mut pings_received = 0usize;
        let mut pongs_received = 0usize;
        let mut last_pong_payload: Option<Vec<u8>> = None;

        if self.ready && !self.closed {
            self.record_events = false;
            let _ = self.wire.set_read_timeout(Some(plan.read_timeout));
            let mut parser = FrameParser::new();
            let mut buf = [0u8; STREAM_READ_BUF];
            let start = Instant::now();
            let mut last_ping = start;

            loop {
                if self.closed {
                    break;
                }
                if plan.send_ping && Instant::now().duration_since(last_ping) >= plan.ping_interval
                {
                    let payload = match plan.ping_payload {
                        Some(bytes) => bytes.to_vec(),
                        None => HeartbeatPayload::encode(monotonic_nanos()),
                    };
                    self.send(MessageType::Ping, 0, &payload);
                    last_ping = Instant::now();
                }
                if self.closed {
                    break;
                }
                if Instant::now().duration_since(start) >= plan.max_duration
                    || plan.stop_after_inputs.is_some_and(|n| inputs.len() >= n)
                {
                    self.close_sending_bye("user");
                    break;
                }

                match self.wire.read_available(&mut buf) {
                    Ok(0) => {
                        self.mark_transport_closed();
                        break;
                    }
                    Ok(n) => match parser.append(&buf[..n]) {
                        Ok(frames) => {
                            for frame in frames {
                                let keep = self.handle_source_stream_frame(
                                    frame,
                                    plan.echo_pong,
                                    &mut inputs,
                                    &mut pings_received,
                                    &mut pongs_received,
                                    &mut last_pong_payload,
                                );
                                if !keep {
                                    break;
                                }
                            }
                        }
                        Err(_) => {
                            self.close_sending_bye("transport");
                            break;
                        }
                    },
                    Err(ref e) if wire::is_timeout(e) => {}
                    Err(_) => {
                        self.mark_transport_closed();
                        break;
                    }
                }
            }
        }

        SourceStreamResult {
            outcome: self.into_outcome(),
            inputs,
            pings_received,
            pongs_received,
            last_pong_payload,
        }
    }

    /// Source-side streaming dispatch (test helper): collect INPUT, count PING/PONG (echo PONG if
    /// asked), stop on BYE. Returns `false` to stop the loop.
    fn handle_source_stream_frame(
        &mut self,
        frame: sidewire_proto::Frame,
        echo_pong: bool,
        inputs: &mut Vec<InputEventRecord>,
        pings_received: &mut usize,
        pongs_received: &mut usize,
        last_pong_payload: &mut Option<Vec<u8>>,
    ) -> bool {
        let msg_type = match frame.message_type() {
            Some(t) => t,
            None => return true, // unknown/reserved → skip
        };
        match msg_type {
            MessageType::Input => inputs.extend(InputEventRecord::decode_batch(&frame.payload)),
            MessageType::Ping => {
                *pings_received += 1;
                if echo_pong {
                    self.send(MessageType::Pong, 0, &frame.payload);
                }
            }
            MessageType::Pong => {
                *pongs_received += 1;
                *last_pong_payload = Some(frame.payload.clone());
            }
            MessageType::Bye => {
                self.handle_bye(&frame.payload);
                return false;
            }
            _ => {}
        }
        !self.closed
    }

    /// Record an inbound frame in the event log (no-op once streaming turns recording off).
    fn record_recv(&mut self, raw_type: u8) {
        if self.record_events {
            self.events.push(WireEvent {
                dir: Dir::Recv,
                raw_type,
            });
        }
    }

    /// EOF or transport failure. If the peer already told us a reason (BYE), keep it; otherwise this
    /// is a canonical transport failure.
    fn mark_transport_closed(&mut self) {
        if !self.closed {
            self.close_reason = Some("transport".to_string());
            self.closed = true;
        }
    }

    fn into_outcome(self) -> SessionOutcome {
        SessionOutcome {
            config: self.negotiated_config,
            close_reason: self.close_reason,
            events: self.events,
        }
    }

    /// Streaming-phase dispatch (after CONFIG): VIDEO → decode callback; PING → PONG; BYE → close;
    /// PAUSE/RESUME acknowledged as liveness only. Unknown/reserved types are skipped.
    fn handle_stream_frame<F>(&mut self, frame: sidewire_proto::Frame, on_video: &mut F)
    where
        F: FnMut(&[u8], bool, u64),
    {
        let msg_type = match frame.message_type() {
            Some(t) => t,
            None => return, // unknown/reserved → skip (forward compatibility)
        };
        match msg_type {
            MessageType::Video => {
                let keyframe = frame.flags & video_flags::KEYFRAME != 0;
                if let Some((_ltr, pts, nal)) = VideoPayload::decode(&frame.payload) {
                    on_video(&nal, keyframe, pts);
                }
            }
            // Echo the exact 8 bytes back (docs/02 § PING/PONG) so the peer's RTT is on its clock.
            MessageType::Ping => self.send(MessageType::Pong, 0, &frame.payload),
            MessageType::Bye => self.handle_bye(&frame.payload),
            // PAUSE/RESUME/PONG/etc. just keep the link warm; nothing to do at M2.
            _ => {}
        }
    }

    // MARK: - Sending

    fn next_seq(&mut self) -> u32 {
        let s = self.seq;
        self.seq = self.seq.wrapping_add(1);
        s
    }

    fn send(&mut self, msg_type: MessageType, flags: u8, payload: &[u8]) {
        if self.closed {
            return;
        }
        let seq = self.next_seq();
        if self.record_events {
            self.events.push(WireEvent {
                dir: Dir::Sent,
                raw_type: msg_type.as_u8(),
            });
        }
        if self
            .wire
            .write_frame(msg_type.as_u8(), flags, seq, payload)
            .is_err()
        {
            if self.close_reason.is_none() {
                self.close_reason = Some("transport".to_string());
            }
            self.closed = true;
        }
    }

    fn send_json<T: serde::Serialize>(&mut self, msg_type: MessageType, value: &T) {
        let payload = serde_json::to_vec(value).unwrap_or_default();
        self.send(msg_type, 0, &payload);
    }

    fn send_bye(&mut self, reason: &str) {
        let msg = ReasonMessage::new(reason);
        self.send_json(MessageType::Bye, &msg);
    }

    /// Send a BYE(reason) then close. The BYE is flushed by [`Wire::write_frame`] before the socket
    /// is later dropped, so the peer receives the reason rather than a bare reset.
    fn close_sending_bye(&mut self, reason: &str) {
        self.send_bye(reason);
        self.finish_close(Some(reason.to_string()));
    }

    fn finish_close(&mut self, reason: Option<String>) {
        if self.closed {
            return;
        }
        self.closed = true;
        self.close_reason = reason;
    }

    // MARK: - Pairing decision (CPace, pre-HELLO)

    /// Decide, once TLS is ready, whether to run CPace or go straight to HELLO. Mirrors
    /// `beginPairingOrHandshake`. The **Source leads**; the Display waits for the Source's lead.
    fn begin_pairing_or_handshake(&mut self) {
        let already_paired = self
            .pairing
            .trust_store
            .pinned(&self.tls.peer_device_id)
            .map(|p| p.spki_hash == hex_lower(&self.tls.peer_spki_hash))
            .unwrap_or(false);

        if self.role == Role::Source {
            if already_paired {
                self.begin_application_handshake();
            } else {
                match self.make_cpace_share() {
                    Some((scalar, share)) => {
                        self.cpace_scalar = Some(scalar);
                        self.cpace_own_share = Some(share);
                        self.awaiting_peer_share = true;
                        self.send(MessageType::PairMsg, 0, &share);
                    }
                    None => self.close_sending_bye("auth"),
                }
            }
        }
        // Display: react to the Source's lead in `handle` (never send first).
    }

    /// Compute the generator `g` from PIN + channel binding and derive a fresh CPace scalar/share.
    fn make_cpace_share(&self) -> Option<([u8; 32], [u8; 32])> {
        let sid = cpace::sid(&self.tls.channel_binding);
        let g = cpace::calculate_generator(&self.pairing.pin, &self.tls.channel_binding, &sid);
        let scalar = cpace::sample_scalar();
        let share = cpace::scalar_mult(&scalar, &g)?;
        Some((scalar, share))
    }

    /// A PAIR_MSG (peer CPace share) arrived. Source: finish the exchange, send our confirmation.
    /// Display: run the responder — reply with our share, WITHHOLD our tag, await the Source's tag.
    /// Mirrors `handlePairMsg`.
    fn handle_pair_msg(&mut self, payload: &[u8]) {
        if payload.len() != cpace::ELEMENT_BYTES {
            self.close_sending_bye("auth");
            return;
        }
        let peer_share = payload.to_vec();
        let sid = cpace::sid(&self.tls.channel_binding);

        if self.role == Role::Display {
            if self.pairing_replied {
                return; // one responder run per attempt
            }
            // Rate-limit online guessing BEFORE the (comparatively costly) CPace work.
            if let Some(limiter) = &self.pairing.rate_limiter {
                if !limiter.allow_attempt() {
                    self.close_sending_bye("rateLimited");
                    return;
                }
            }
            // Compute g/yb/Yb and K = scalar_mult_vfy(yb, Ya). A low-order Source share (or a
            // generator failure) → abort per the draft.
            let derived = self.make_cpace_share().and_then(|(yb, own_share)| {
                cpace::scalar_mult_vfy(&yb, &peer_share).map(|k| (own_share, k))
            });
            let (own_share, k) = match derived {
                Some(v) => v,
                None => {
                    if let Some(limiter) = &self.pairing.rate_limiter {
                        limiter.record_failure();
                    }
                    self.close_sending_bye("auth");
                    return;
                }
            };
            // Transcript is initiator(Source=Ya) first, responder(Display=Yb) second.
            let isk = cpace::derive_isk(&sid, &k, &peer_share, b"", &own_share, b"");
            let mac_key = cpace::derive_mac_key(&sid, &isk);
            self.cpace_expected_peer_tag =
                Some(cpace::confirmation_tag(&mac_key, &peer_share, b""));
            self.cpace_mac_key = Some(mac_key);
            self.cpace_own_share = Some(own_share);
            self.pairing_replied = true;
            // Send ONLY our share now — Tb is WITHHELD until the Source's Ta verifies (security-
            // critical: otherwise a single guess-share harvests Tb without charging the rate limiter).
            self.send(MessageType::PairMsg, 0, &own_share);
        } else {
            // .source: this is the Display's share (Yb).
            if !self.awaiting_peer_share {
                return;
            }
            let ya = match self.cpace_scalar {
                Some(s) => s,
                None => return,
            };
            let own_share = match self.cpace_own_share {
                Some(s) => s,
                None => return,
            };
            self.awaiting_peer_share = false;
            let k = match cpace::scalar_mult_vfy(&ya, &peer_share) {
                Some(k) => k,
                None => {
                    self.close_sending_bye("auth");
                    return;
                }
            };
            let isk = cpace::derive_isk(&sid, &k, &own_share, b"", &peer_share, b"");
            let mac_key = cpace::derive_mac_key(&sid, &isk);
            self.cpace_expected_peer_tag =
                Some(cpace::confirmation_tag(&mac_key, &peer_share, b""));
            let ta = cpace::confirmation_tag(&mac_key, &own_share, b"");
            self.send(MessageType::PairConfirm, 0, &ta);
        }
    }

    /// A PAIR_CONFIRM (peer key-confirmation tag) arrived. Verify it constant-time. Mirrors
    /// `handlePairConfirm`.
    fn handle_pair_confirm(&mut self, payload: &[u8]) {
        let expected = match self.cpace_expected_peer_tag.take() {
            Some(e) => e,
            None => return, // one confirmation per attempt
        };
        let ok = cpace::constant_time_equals(payload, &expected);
        if self.role == Role::Display {
            if ok {
                if let Some(limiter) = &self.pairing.rate_limiter {
                    limiter.record_success();
                }
                // The Source's tag verified — only NOW release our own (Tb) and pin the peer.
                let tb = match (self.cpace_mac_key.as_ref(), self.cpace_own_share.as_ref()) {
                    (Some(mk), Some(os)) => Some(cpace::confirmation_tag(mk, os, b"")),
                    _ => None,
                };
                if let Some(tb) = tb {
                    self.send(MessageType::PairConfirm, 0, &tb);
                }
                self.pin_peer();
                self.clear_cpace_state();
                self.begin_application_handshake();
            } else {
                if let Some(limiter) = &self.pairing.rate_limiter {
                    limiter.record_failure();
                }
                self.close_sending_bye("auth");
            }
        } else {
            // .source
            if ok {
                self.pin_peer();
                self.clear_cpace_state();
                self.begin_application_handshake();
            } else {
                self.close_sending_bye("auth");
            }
        }
    }

    /// The Display received a HELLO before pairing completed: the Source skipped CPace, so it
    /// considers itself paired. Accept only if we have it pinned too (paired reconnect); else refuse.
    /// Mirrors `handlePreHandshakeHello`.
    fn handle_pre_handshake_hello(&mut self, frame: sidewire_proto::Frame) {
        if self.role != Role::Display {
            return;
        }
        if self
            .pairing
            .trust_store
            .pinned(&self.tls.peer_device_id)
            .is_some()
        {
            self.begin_application_handshake();
            self.handle(frame); // now process the HELLO through the normal path
        } else {
            self.close_sending_bye("auth");
        }
    }

    fn pin_peer(&mut self) {
        let name = self
            .peer_hello
            .as_ref()
            .map(|h| h.device_name.clone())
            .unwrap_or_default();
        let peer = TrustedPeer::new(
            self.tls.peer_device_id.clone(),
            hex_lower(&self.tls.peer_spki_hash),
            name,
        );
        self.pairing.trust_store.pin(peer);
    }

    fn clear_cpace_state(&mut self) {
        self.cpace_scalar = None;
        self.cpace_own_share = None;
        self.cpace_mac_key = None;
        self.cpace_expected_peer_tag = None;
    }

    // MARK: - Application handshake

    /// Begin the HELLO exchange. Called directly on a paired reconnect, or after CPace succeeds.
    /// Mirrors `beginApplicationHandshake` (heartbeat/streaming are later milestones).
    fn begin_application_handshake(&mut self) {
        if self.app_handshake_started {
            return;
        }
        self.app_handshake_started = true;
        self.send_json(MessageType::Hello, &self.local_hello.clone());
        // DISPLAY_INFO is deferred until AFTER the peer's HELLO is validated (see receive_hello).
    }

    fn handle(&mut self, frame: sidewire_proto::Frame) {
        if self.closed {
            return;
        }
        let msg_type = match frame.message_type() {
            Some(t) => t,
            None => return, // unknown/reserved type → skip (forward compatibility)
        };

        // Pre-handshake pairing gate: until the app handshake begins, only pairing messages (+ BYE).
        if !self.app_handshake_started {
            match msg_type {
                MessageType::PairMsg => self.handle_pair_msg(&frame.payload),
                MessageType::PairConfirm => self.handle_pair_confirm(&frame.payload),
                MessageType::Hello | MessageType::HelloAck => {
                    self.handle_pre_handshake_hello(frame)
                }
                MessageType::Bye => self.handle_bye(&frame.payload),
                _ => {} // ignore video/input/etc. until pairing completes
            }
            return;
        }

        match msg_type {
            MessageType::Hello | MessageType::HelloAck => {
                match serde_json::from_slice::<Hello>(&frame.payload) {
                    Ok(hello) => self.receive_hello(hello, msg_type == MessageType::HelloAck),
                    Err(_) => self.close_sending_bye("protocol"),
                }
            }
            MessageType::DisplayInfo => {
                if self.role == Role::Source {
                    match serde_json::from_slice::<DisplayInfo>(&frame.payload) {
                        Ok(info) => {
                            self.peer_display_info = Some(info);
                            self.finalize_if_possible();
                        }
                        Err(_) => self.close_sending_bye("protocol"),
                    }
                }
            }
            MessageType::Config => {
                if self.role == Role::Display {
                    match serde_json::from_slice::<Config>(&frame.payload) {
                        Ok(cfg) => self.become_ready(cfg),
                        Err(_) => self.close_sending_bye("protocol"),
                    }
                }
            }
            MessageType::Bye => self.handle_bye(&frame.payload),
            // video/input/ping/pong/etc are not needed to reach CONFIG in M1.
            _ => {}
        }
    }

    fn handle_bye(&mut self, payload: &[u8]) {
        let reason = serde_json::from_slice::<ReasonMessage>(payload)
            .ok()
            .map(|r| r.reason);
        self.finish_close(reason);
    }

    /// Mirrors `receiveHello`: validate, reply HELLO_ACK, and (Display) emit DISPLAY_INFO.
    fn receive_hello(&mut self, hello: Hello, is_ack: bool) {
        if let Some(rejection) = hello.validate(self.role) {
            self.close_sending_bye(rejection.reason());
            return;
        }
        // The peers must agree on the wire input encoding (both v2 peers send "hid1").
        if hello.capabilities.input_mapping != self.local_hello.capabilities.input_mapping {
            self.close_sending_bye("protocol");
            return;
        }
        if self.peer_hello.is_none() {
            // If the peer was pinned before its HELLO (name unknown then), fill in the human name.
            if let Some(pinned) = self.pairing.trust_store.pinned(&self.tls.peer_device_id) {
                if pinned.name != hello.device_name {
                    let updated = TrustedPeer {
                        name: hello.device_name.clone(),
                        ..pinned
                    };
                    self.pairing.trust_store.pin(updated);
                }
            }
            self.peer_hello = Some(hello);
            if !is_ack {
                // Reply with our HELLO_ACK so the peer has our capabilities regardless of order.
                self.send_json(MessageType::HelloAck, &self.local_hello.clone());
            }
            // The Display sends DISPLAY_INFO only now — after the Source's HELLO is validated (right
            // after our HELLO_ACK) — so a rejected peer never learns our panel description.
            if self.role == Role::Display {
                if let Some(info) = self.display_info.clone() {
                    self.send_json(MessageType::DisplayInfo, &info);
                }
            }
        }
        self.finalize_if_possible();
    }

    /// Source-side: once we have the peer HELLO and the Display's info, compute + send CONFIG.
    /// Mirrors `finalizeIfPossible`.
    fn finalize_if_possible(&mut self) {
        if self.role != Role::Source || self.config_sent {
            return;
        }
        let peer = match self.peer_hello.clone() {
            Some(p) => p,
            None => return,
        };
        let info = match self.peer_display_info.clone() {
            Some(i) => i,
            None => return, // need the display info to size the virtual display exactly
        };
        match Self::negotiate(&self.local_hello, &peer, &info) {
            Some(cfg) => {
                self.config_sent = true;
                self.send_json(MessageType::Config, &cfg);
                self.become_ready(cfg);
            }
            // No shared video codec ⇒ fail loudly (BYE "protocol") rather than stream undecodably.
            None => self.close_sending_bye("protocol"),
        }
    }

    fn become_ready(&mut self, cfg: Config) {
        if self.ready {
            return;
        }
        self.ready = true;
        self.negotiated_config = Some(cfg);
    }

    /// Negotiate the streaming config = intersection of capabilities + the Display's native sizing.
    /// A simplified port of `Session.negotiate` (no Source-side overrides in M1).
    fn negotiate(local: &Hello, peer: &Hello, info: &DisplayInfo) -> Option<Config> {
        let codec = local
            .capabilities
            .video_codecs
            .iter()
            .find(|c| peer.capabilities.video_codecs.contains(c))?
            .clone();
        let fps = local.capabilities.max_fps.min(peer.capabilities.max_fps);
        let ltr = local.capabilities.ltr && peer.capabilities.ltr;
        // Match the Display's scale: scaleFactor >= 2 ⇒ HiDPI, else 1×.
        let hi_dpi = info.scale_factor >= 2.0;
        let max_bps: i64 = 50_000_000;
        Some(Config {
            codec,
            width: info.width,
            height: info.height,
            fps,
            ltr,
            bitrate_start_bps: 30_000_000i64.min(max_bps),
            bitrate_min_bps: 5_000_000i64.min(max_bps),
            bitrate_max_bps: max_bps,
            hi_dpi,
        })
    }
}

/// Lowercase hex encoding — matches the Swift trust store's `spkiHash` string form.
fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
