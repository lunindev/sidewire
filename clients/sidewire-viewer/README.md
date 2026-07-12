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

Done and verified (`cargo test`, 31 tests):

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

### Not yet done (later milestones)
- **M2:** H.264/HEVC decode (ffmpeg, hw where available) + a window; glass-to-glass latency.
- **M3:** borderless fullscreen + input capture (winit → HID usages) + the ≤2.5 s heartbeat/watchdog
  liveness contract & reconnect parity. *(M1's blocking IO has only a coarse 30 s socket timeout as
  interim protection against a stalled peer; the real heartbeat lands here.)*
- **M4:** mDNS discovery (`_sidewire._tcp`) + manual-IP fallback + packaging (Windows, Linux).

## ⚠️ Untested on real hardware
Nothing here has run against a live **Mac Source** yet. Byte-for-byte vector conformance + a Rust↔Rust
loopback are proven; **live Rust↔Swift interop** (a real TLS 1.3 handshake + channel-binding agreement
on genuine leaf certs, and end-to-end pairing) and **real M4↔i9 hardware** remain open. Confirm before
any release.

## Build & test

```sh
cd clients/sidewire-viewer
cargo test                 # 31 tests: golden vectors + CPace draft vectors + TLS loopback pairing
cargo build --release      # the sidewire-viewer binary
cargo run --bin sidewire-viewer [port]   # M1 demo: listen, print PIN, run one Display session to CONFIG
```

Toolchain: Rust ≥ 1.90; one crypto backend (`ring`, via rustls + rcgen) — no `openssl`/`aws-lc-rs`
crate dependency (the OpenSSL **CLI** is only used, if present, for one identity cross-check test).
ffmpeg/window deps arrive with M2. `target/` is git-ignored; `Cargo.lock` is committed (this is a bin).
