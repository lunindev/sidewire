# Sidewire — Rust Display client (Windows/Linux)

Native cross-platform **Display** client for Sidewire (Phase 8, [docs/09 §Phase 8](../../docs/09-next-stage.md),
[docs/11-status-and-gaps.md](../../docs/11-status-and-gaps.md)). The Rust client is **always the Display** — it listens,
is the **CPace responder**, decodes/presents the incoming stream, and sends input back. The Mac is
always the **Source** (dialer, CPace initiator, virtual-display owner).

The wire protocol and pairing crypto are the **fixed conformance target** in
[`docs/02-protocol.md`](../../docs/02-protocol.md) (wire, normative),
[`docs/05-security-and-pairing.md`](../../docs/05-security-and-pairing.md) (pairing crypto, normative),
and the machine-checkable golden vectors in [`../../protocol-vectors/`](../../protocol-vectors/). This
crate reproduces them byte-for-byte; **do not edit** the vectors or the Swift reference to make a test pass.

## Status — Milestone M1 (protocol + crypto + transport foundation) ✅

- **`sidewire-proto`** — pure wire protocol: 12-byte framing + incremental parser, JSON control
  messages (HELLO/CONFIG/DISPLAY_INFO/BYE), 32-byte HID `INPUT` records, VIDEO payload + PTS.
  Reproduces `frame`/`input`/`video`-vectors byte-for-byte and `message`-vectors semantically.
- **`sidewire-crypto`** — CPace (`CPACE-X25519-SHA512-ELLIGATOR2`, `draft-irtf-cfrg-cpace-21`) with a
  hand-rolled `Field25519` + `Elligator2` (curve25519-dalek's Elligator is not public), X25519 via
  `x25519-dalek`; P-256 self-signed identity via `rcgen`; `spki_hash`/`device_id` per docs/05.
  Reproduces the CPace draft's published vectors **and** `pairing-vectors.json` byte-for-byte; the
  SPKI/deviceId derivation is cross-checked against the OpenSSL CLI.
- **`sidewire-viewer`** — rustls **TLS 1.3** listener (mutual auth, accept-any cert **but real
  proof-of-possession**, self-signed P-256), an in-memory trust store, a rate limiter, and the
  CPace-responder session state machine driving a connection to CONFIG. A Rust↔Rust loopback test
  runs a real TLS 1.3 handshake + first-time pairing, wrong-PIN → `BYE("auth")`, paired-reconnect
  (skips CPace), and rate-limit lockout.

## Status — Milestone M2 (video decode + a window) ✅

- **`sidewire-media`** (new crate) — H.264/HEVC **Annex-B software decode** via libavcodec (ffmpeg
  7.x, the `ffmpeg-the-third` crate). Feeds one self-contained access unit at a time straight to
  libavcodec (no demuxer/format context — the stream is clean Annex-B with in-band parameter sets,
  docs/04), carries the **wire PTS** through unchanged (a FIFO, since there are no B-frames), gates on
  a first keyframe, and rebuilds on a hard decode error. Also an Annex-B AU splitter + codec sniffer.
  A `DecodeBackend` trait is the seam a hardware backend slots into later (see below).
- **`sidewire-viewer` rendering** — a **wgpu** renderer that uploads a decoded frame's YUV planes as
  textures and converts **YUV→RGB in a fragment shader** (BT.709 limited-range), drawing a full-screen
  quad with **aspect-fit letterboxing**; the rendered video rect is exposed for M3's input mapping
  (docs/02 § INPUT). Supports **YUV420P** (SW decode) and **NV12** (future HW). A **winit 0.30**
  window (`ApplicationHandler`) runs the event loop on the main thread; the network/decode runs on a
  worker thread and posts the *latest* frame to the renderer (stale frames dropped, not queued).
- **Session streaming** — `Session::run_streaming(on_video)` extends the Display past CONFIG into a
  streaming loop: each `VIDEO` frame is parsed (subheader PTS + FRAME keyframe bit) and handed to a
  callback; `PING`→`PONG` and `BYE` are honored. The M1 `run()` (stops at CONFIG) is unchanged.
- **Latency instrumentation** — `stats::FrameStats`/`LatencyTracker` expose local receive→decode and
  decode→present deltas + the wire PTS. **Honest scope:** true cross-machine *glass-to-glass* latency
  can't be measured here — the PTS epoch is the Source's arbitrary monotonic clock (docs/02) and there
  is no live Mac; M2 provides the instrumentation, real numbers come on hardware.

### Deferred / not yet done
- **Hardware decode is deferred to M3+.** M2 ships robust software decode as the baseline. The
  `sidewire_media::DecodeBackend` trait is the decode-backend seam; a VideoToolbox / D3D11VA / VAAPI
  backend can implement it (a moonlight-qt-style ladder) without touching the keyframe-gate / rebuild
  logic — see the `TODO(M3+)` in `sidewire-media/src/decoder.rs`.
- **M3:** borderless fullscreen + input capture (winit → HID usages) + the ≤2.5 s heartbeat/watchdog
  liveness contract & reconnect parity. *(Blocking IO still has only a coarse 30 s socket timeout as
  interim protection against a stalled peer; the real heartbeat lands here.)*
- **M4:** mDNS discovery (`_sidewire._tcp`) + manual-IP fallback + packaging (Windows, Linux).

## ⚠️ Untested on real hardware
Nothing here has run against a live **Mac Source** yet. Byte-for-byte vector conformance, a Rust↔Rust
loopback (handshake + first-time pairing/reconnect/rate-limit), and an **end-to-end Rust↔Rust video
loopback** (Source replays a fixture clip → Display decodes 5 frames over real TLS 1.3) are proven, and
the decode+render pipeline is validated headlessly (offscreen wgpu render of a known YUV frame). Still
open: **live Rust↔Swift interop** (a real TLS 1.3 handshake + channel binding on genuine leaf certs;
Rust decoding a real VideoToolbox HEVC/H.264 stream) and **real M4↔i9 hardware**. Confirm before any
release.

## Build & test

```sh
cd clients/sidewire-viewer
cargo test                 # 44 tests: golden vectors + CPace draft + TLS loopback + decode + render
cargo build --release      # the sidewire-viewer binary
cargo run --bin sidewire-viewer -- --file <clip.h264|.h265>   # decode a local clip → window (no Mac)
cargo run --bin sidewire-viewer -- [port]                     # listen: pair → CONFIG → stream → window
cargo run --bin sidewire-viewer -- --handshake-only [port]    # M1 behavior: run one session to CONFIG
```

Toolchain: Rust ≥ 1.90. Crypto is one backend (`ring`, via rustls + rcgen) — no `openssl`/`aws-lc-rs`
crate (the OpenSSL **CLI** is only used, if present, for one identity cross-check test). Video decode
links **ffmpeg 7.x** (only `sidewire-media` does; the rest of the tree stays ring-only); the window
uses **wgpu** + **winit**. `target/` is git-ignored; `Cargo.lock` is committed (this is a bin).

### ffmpeg 7.x build/run env

`sidewire-media` links **libavcodec 61 (ffmpeg 7.x)** via `ffmpeg-the-third`. On Linux/Windows a system
ffmpeg 7.x on the default `pkg-config` path needs no extra env. On **macOS**, `brew`'s `ffmpeg@7` is
keg-only, so the build (bindgen) and the tests/bin (dylib load) need three vars — export them before
any `cargo` command that touches the media crate:

```sh
export FFMPEG_DIR="$(brew --prefix ffmpeg@7)"
export PKG_CONFIG_PATH="$FFMPEG_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$FFMPEG_DIR/lib:$DYLD_FALLBACK_LIBRARY_PATH"
```

(Without `FFMPEG_DIR` the bindgen build fails to find the libav* headers; without
`DYLD_FALLBACK_LIBRARY_PATH` the tests/bin fail to load libav* at runtime. This is a macOS keg-only
quirk only — do **not** hardcode a mac path into any committed `.cargo/config.toml`.)

### Test fixtures
Tiny (~5 KB) Annex-B clips live in `sidewire-media/tests/fixtures/` (`clip.h264`, `clip.h265`) — 320×240,
5 frames, no B-frames, in-band parameter sets. Regeneration commands are in that directory's
`README.md`.
