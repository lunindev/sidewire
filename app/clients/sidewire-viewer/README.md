# Sidewire — Rust Display client (Windows/Linux)

Native cross-platform **Display** client for Sidewire (Phase 8, [docs/00 §D10](../../docs/00-decisions.md),
[docs/08-status-and-gaps.md](../../docs/08-status-and-gaps.md)). The Rust client is **always the Display** — it listens,
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
- **Hardware decode is deferred.** M2 ships robust software decode as the baseline. The
  `sidewire_media::DecodeBackend` trait is the decode-backend seam; a VideoToolbox / D3D11VA / VAAPI
  backend can implement it (a moonlight-qt-style ladder) without touching the keyframe-gate / rebuild
  logic — see the `TODO(M3+)` in `sidewire-media/src/decoder.rs`.

## Status — Milestone M3 (input capture + heartbeat/watchdog + fullscreen + re-listen) ✅

- **`sidewire-viewer::input`** — winit `WindowEvent`s → platform-neutral `InputEventRecord`s
  (docs/02 § INPUT), a faithful port of the Mac Display's `InputCapture.swift` + `KeyMapping.swift`:
  - `input::keymap::hid_usage` maps every winit `KeyCode` to the **same USB-HID usage** as
    `HIDKeyboardMap.swift` (`KeyA`→0x04, `Enter`→0x28, `ArrowUp`→0x52, `ShiftLeft`→0xE1, …); an
    unmapped key returns `None` (dropped, never sent as an ambiguous 0);
  - `InputTranslator` (a pure, unit-testable struct — no window needed) normalizes pointer coords
    `0..1` into the **rendered video rect** (aspect-fit letterbox, clamped; no Y-flip — winit's
    top-left origin already matches the wire), tracks left/right drag + double-click multiplicity,
    emits scroll deltas in **pixels** (line deltas × `LINE_SCROLL_PX`), maps modifier keys to
    `flagsChanged` + the HID boot-protocol modifier byte (left-hand bit), and keeps **⌘/Super combos
    and Escape LOCAL** (never forwarded, key-state balanced) so the user always keeps control of the
    Display machine and can exit fullscreen.
- **Heartbeat / watchdog / streaming IO** — `Session::run_streaming` now runs all three streaming
  duties on **one TLS connection, single-threaded** (no concurrent-write race): receive VIDEO, send
  INPUT drained from an mpsc channel, and run the heartbeat. The streaming read switches from the
  blocking `read_frame` to a **short-timeout incremental** read (`Wire::read_available` at a ~5 ms
  socket timeout, feeding a `FrameParser`), so a timed-out read just means "no frame yet". Per
  iteration it drains INPUT, PINGs every `HEARTBEAT_INTERVAL`, echoes inbound PING→PONG, resets the
  watchdog on **any** inbound frame, and closes with reason `"timeout"` after
  `HEARTBEAT_TIMEOUT` of silence. Timing is injectable via `HeartbeatConfig` (defaults 500 ms /
  2500 ms; tests use ~20 ms / ~100 ms).
- **Window** — `F11` toggles **borderless fullscreen** (`Fullscreen::Borderless(None)`), `Esc` exits
  it; both stay local (Esc is also reserved-local in the translator). The winit thread feeds every
  event to the `InputTranslator` and forwards records to the worker over an mpsc channel; the
  renderer's video rect is pushed into the translator on each render so pointer mapping tracks the
  letterbox.
- **Display re-listen loop** — the listen worker wraps accept+session in a loop: when a session ends
  (timeout / transport / BYE / user), it returns to `accept()` for the next Source (the Source is the
  reconnecting dialer, docs/03), keeping the window open, and exits only when the window closes.

### M3 deferred
- **Middle / extra mouse buttons** are dropped (only left/right cross the wire, matching the Mac).
- The **handshake phase** still uses the coarse 30 s socket timeout; the fine-grained ≤2.5 s
  heartbeat/watchdog governs the streaming phase (where a live static-screen session actually sits).
- A live **Rust↔Swift** input round-trip (a real Mac Source injecting the HID usages) and the actual
  fullscreen/latency feel need a live Mac — see below.

## Status — Milestone M4 (mDNS discovery + manual-IP + packaging) ✅

- **`sidewire-viewer::discovery`** — mDNS/DNS-SD via the `mdns-sd` crate. The Rust client is always the
  **Display**, so its core job is to **advertise** `_sidewire._tcp` — the exact contract a Mac Source
  browses (`Discovery.swift`) and dials:
  - `Advertiser` registers `_sidewire._tcp.local.` at the listener port with instance name = the
    Display's device name and TXT **`did` = deviceId** (+ optional **`tb`** Thunderbolt IP), mirroring
    `TCPListener.swift` (`NWListener.Service`) + `DisplayController.swift`. Drop/`stop()` unregisters.
    The service type reuses `sidewire_proto`'s `BONJOUR_SERVICE_TYPE` (`_sidewire._tcp`, docs/02).
  - `peer_from_service_info` is a **pure** parser (no network) extracting `did`/`tb` from TXT (a value
    is taken only when present *and* non-empty, mirroring Swift's `txtValue`); `discover()`/`browse()`
    drive the `--discover` diagnostic. Because the daemon-free construction/parse path is pure, the TXT
    logic is **unit-tested without multicast** (live multicast doesn't resolve in this dev/CI env — a
    browse gets `SearchStarted` but never `ServiceResolved`), and the one live advertise→browse
    round-trip is `#[ignore]`d (documented to run on a real LAN).
- **Wired into the Display** — listen mode starts advertising `did = deviceId` at the bound port and
  keeps it up across the re-listen loop (unregisters on shutdown). The listener defaults to port
  **5005** — the documented **manual-IP fallback** — and advertises that exact port, so a Source can
  connect by `IP:5005` with zero discovery infrastructure. A **`--discover [secs]`** mode browses and
  prints nearby Sidewire Displays (diagnostic).
- **Graceful close on window close** — the window's stop flag is threaded into
  `Session::run_streaming`/`stream_loop`; when the user closes the window the loop sends **`BYE("user")`**
  and unwinds, and `window::run` **joins the worker** after the event loop exits so that BYE is flushed
  before the process ends (the Source sees a clean goodbye instead of waiting out its 2.5 s watchdog).
- **Packaging scaffolding** — [`packaging/`](packaging/): a per-OS recipe [`README.md`](packaging/README.md)
  (ffmpeg 7.x dynamic-lib bundling vs static link; wgpu's GPU-driver requirement; Windows `.zip`/MSI,
  Linux AppImage/`.deb`) and a Linux [`sidewire-viewer.desktop`](packaging/sidewire-viewer.desktop).
  **Scaffolding only — see below.**

### M4 deferred / honest scope
- **Packaging is documentation only, NOT built artifacts.** No Windows `.zip`/MSI or Linux
  AppImage/`.deb` has been produced or run — the cross toolchains and target-OS ffmpeg/wgpu libs are
  out of reach on this macOS box. A real build must stand up Windows/Linux runners, install ffmpeg 7.x,
  `cargo build --release`, and bundle the *actual* linked libs (read off `ldd`/`dumpbin`, don't trust
  the illustrative soname list). See [`packaging/README.md`](packaging/README.md).
- **No `tb` (Thunderbolt) TXT yet** — the Rust Display has no interface-monitor equivalent to the Mac's
  `InterfaceMonitor.localThunderboltIP()`, so it advertises `did` only. A Source's Wi-Fi connect still
  works; a one-click cable connect would need the Rust side to discover its own TB link-local IP.
- **No live mDNS interop.** The advertise/parse logic is proven structurally + against the Swift
  contract by inspection; a real Mac Source browsing and resolving the Rust Display needs a working
  multicast LAN (the `#[ignore]`d round-trip) and remains open, like all Rust↔Swift interop below.

## ⚠️ Untested on real hardware
Nothing here has run against a live **Mac Source** yet. Proven with no Mac: byte-for-byte vector
conformance; a Rust↔Rust loopback (handshake + first-time pairing/reconnect/rate-limit); an
end-to-end Rust↔Rust **video** loopback (Source replays a fixture clip → Display decodes 5 frames over
real TLS 1.3); the decode+render pipeline (offscreen wgpu render of a known YUV frame); and, new in
M3, an **input-send** loopback (INPUT records round-trip Display→Source byte-identically over real
TLS) plus **heartbeat/watchdog** loopbacks (silent Source → `"timeout"`; active Source → stays alive
+ echoes the **exact** PING payload back as PONG); and, new in M4, **structural mDNS** advertise/parse
tests (a constructed `ServiceInfo` recovers `did`/`tb`; missing/empty → `None`) proving the TXT
contract without multicast. Still open and needing a live Mac: **Rust↔Swift interop** (a real TLS 1.3
handshake + channel binding on genuine leaf certs; Rust decoding a real VideoToolbox HEVC/H.264 stream;
the Mac Source **injecting** the HID usages the Rust Display sends; a Mac Source **discovering** the
Rust Display over live mDNS — the `#[ignore]`d round-trip), the actual fullscreen/latency feel, and
**real M4↔i9 hardware**. Confirm before any release.

## Build & test

```sh
cd clients/sidewire-viewer
cargo test                 # 73 tests (+1 #[ignore]d live-mDNS round-trip): vectors + CPace + TLS
                           #   loopback + decode + render + keymap/input (unit) + heartbeat +
                           #   input-send loopbacks + M4 structural mDNS advertise/parse
cargo build --release      # the sidewire-viewer binary
cargo run --bin sidewire-viewer -- --file <clip.h264|.h265>   # decode a local clip → window (no Mac)
cargo run --bin sidewire-viewer -- [port]                     # listen (re-listen loop, default :5005):
                                                              #   advertise _sidewire._tcp, pair → CONFIG
                                                              #   → stream (VIDEO in, INPUT out) → window
cargo run --bin sidewire-viewer -- --handshake-only [port]    # M1 behavior: run one session to CONFIG
cargo run --bin sidewire-viewer -- --discover [secs]          # M4 diagnostic: browse for nearby Displays
```

**Discovery & manual connect:** in listen mode the Display advertises `_sidewire._tcp` (TXT `did`) at
its port and defaults to **5005**. A Mac Source can find it via mDNS, or connect **manually** to
`IP:5005` with no discovery at all (the guaranteed fallback, docs/02 § Constants). Packaging scaffolding
(unbuilt — scaffolding only) lives in [`packaging/`](packaging/).

In the window: **F11** toggles borderless fullscreen, **Esc** exits it. ⌘/Super combos and Esc stay
**local** (never forwarded), so you always keep control of the Display machine.

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
