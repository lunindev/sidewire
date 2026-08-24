# 03 — Reliability

This is the subsystem that justifies the app's existence. It lives mostly in `SidewireCore` (the `Session` actor and the reconnect engine), with two media-side watchdogs in the app target. Read [00 D5](00-decisions.md) for the decision and [01 § Concurrency](01-architecture.md#concurrency-model-swift-concurrency) for how it's isolated.

The guiding principle: **never rely on TCP to tell you a peer died, and never infer liveness from video frames.** A static screen produces zero frames legitimately; a pulled cable's `send()` blocks or retries for minutes. Liveness comes from an explicit heartbeat plus interface monitoring; video is only a *quality* signal.

## The three liveness detectors

Three independent detectors feed the `Session` state machine. Any one firing can trigger a transition; they back each other up.

1. **Application heartbeat (primary).** Both peers send `PING` every `HEARTBEAT_INTERVAL` (500 ms) and echo `PONG`. If a peer receives no `PONG`/traffic for `HEARTBEAT_TIMEOUT` (2500 ms → ~5 missed), it declares the peer dead. This is the primary detector because it works regardless of interface state and distinguishes "idle screen" (PONGs still flow) from "dead peer" (they stop).

2. **TCP keepalive + finite drop time (backstop).** On the `NWConnection`'s `NWProtocolTCP.Options`: `enableKeepalive = true`, `keepaliveIdle = 2`, `keepaliveInterval = 1`, `keepaliveCount = 3`, and crucially **`connectionDropTime = 5`** so a `send()` to a vanished peer *fails* within 5 s instead of retrying forever (the current hang). Also `noDelay = true`. When the connection transitions to `.failed`, that's a death signal.

3. **Path monitor (fast interface loss).** An `NWPathMonitor` (and each connection's `viabilityUpdateHandler`) detects the streaming interface going `.unsatisfied` — e.g. the Thunderbolt bridge's `169.254.x.x` disappearing when the cable is pulled — typically in **< 1 s**, faster than either detector above. This is what makes cable-pull recovery feel instant.

**Debounce:** interface flaps (Wi-Fi roam, VPN toggle, brief sleep) must not tear down a healthy session. On `viability == false` or path `.unsatisfied`, start a `VIABILITY_DEBOUNCE` (2500 ms) timer; if it recovers before the timer fires, cancel the teardown. Only a sustained loss enters `reconnecting`.

## Session state machine {#session-state-machine}

One actor, one explicit state enum, all transitions serialized. UI observes a `@MainActor` projection.

```
            ┌─────────┐  user picks/auto  ┌──────────────┐
            │  idle   │ ────────────────► │ discovering  │  (Bonjour browse, or manual IP)
            └─────────┘                   └──────┬───────┘
                 ▲                                │ peer chosen
                 │ user disconnect / BYE(user)    ▼
                 │                         ┌──────────────┐  TLS+TCP
                 │                         │ connecting   │
                 │                         └──────┬───────┘
                 │                                │ transport ready
                 │                                ▼
                 │                         ┌──────────────┐  first time only
                 │                    ┌───►│  pairing     │  (PIN, see 05)
                 │                    │    └──────┬───────┘
                 │              paired│           │ paired/known
                 │                    │           ▼
                 │                    │    ┌──────────────┐  HELLO/HELLO_ACK/
                 │                    └────│ handshaking  │  DISPLAY_INFO/CONFIG
                 │                         └──────┬───────┘
                 │                                │ config applied, first frame
                 │                                ▼
                 │        ┌───────────────► ┌──────────────┐ ◄───────────────┐
                 │        │  recovered      │  streaming   │                 │
                 │        │                 └──┬────────┬──┘                 │
                 │        │      quality drop  │        │  peer sleeping     │
                 │        │                    ▼        ▼                    │
                 │  ┌──────────┐        ┌──────────┐  ┌────────┐             │
                 │  │reconnect-│◄───────│ degraded │  │ paused │─── RESUME ──┘
                 │  │  ing     │ death  └──────────┘  └────────┘
                 │  └────┬─────┘  signal      │ recovered ▲
                 │       │  backoff exhausted  └───────────┘
                 │       │  or fatal
                 ▼       ▼
            ┌──────────────┐  user retry
            │   failed     │ ──────────► discovering
            └──────────────┘
```

State semantics:

| state | meaning | UI |
|-------|---------|----|
| `idle` | not connected | role home screen |
| `discovering` | browsing Bonjour / awaiting manual target | device list, spinner |
| `connecting` | TCP + TLS in progress | "Connecting…" |
| `pairing` | first-time PIN exchange (Phase 3) | PIN entry (source) / PIN display (display) |
| `handshaking` | HELLO↔CONFIG, virtual display sizing | "Setting up…" |
| `streaming` | healthy | live video / status dot green |
| `degraded` | connected but poor (loss/high RTT/queue) | amber banner, HUD |
| `paused` | peer announced sleep | "Source asleep — resuming…" |
| `reconnecting` | lost, retrying with backoff | "Cable unplugged — reconnecting (n)…" |
| `failed` | gave up / needs user action | error + Retry |

Key transition rules:
- **Any death signal** (heartbeat timeout, `.failed` connection, sustained path loss) from `streaming`/`degraded`/`handshaking` → `reconnecting`.
- **`reconnecting`** loops: `forceCancel()` the dead connection, wait `RECONNECT_BACKOFF[n]` (+ jitter), then re-attempt. Re-attempt **re-resolves via Bonjour** (`NWEndpoint.service`) rather than a cached IP, so it works after the Thunderbolt interface returns with a possibly-changed link-local address, and works in discovery mode (fixing the current manual-IP-only limitation). A persisted last-known-good IP is a secondary fallback for manual Thunderbolt links.
- On successful re-handshake, the source **forces an IDR** so the display gets a clean first frame.
- **Backoff** exhausts after `RECONNECT_MAX_ATTEMPTS` only for *fatal* errors (e.g. protocol mismatch, auth failure); network-loss reconnection loops indefinitely at the capped interval while the user leaves it connected (like RDP), because a cable will eventually be replugged.
- **Idempotent resume:** the re-handshake carries the same `sessionId`. The source keeps the virtual display + encoder **alive** across a display-side reconnect so recovery is near-instant and window layout is preserved. Input events include no client-side state that would double-apply; a resumed session does not replay buffered input.

## Watchdogs (media side)

Two watchdogs live in the app target and report to `Session`:

- **Receiver no-frame watchdog** (Display). Decoupled from capture cadence. If no **decoded frame is presented** for `NO_FRAME_DIM` (750 ms) *while the heartbeat still shows the peer alive*, dim the last frame and overlay "Reconnecting…" (never a bare frozen frame). If still nothing at `NO_FRAME_TEARDOWN` (3000 ms), tear down the decoder + connection and enter `reconnecting`. A static screen alone never triggers this because the source sends a periodic refresh/keep-alive frame; but a truly dead pipeline does.
- **Encoder-stall watchdog** (Source). If `ScreenCapture` is delivering frames but `VideoEncoder` produces no output for `ENCODER_WATCHDOG` (1000 ms), recreate the `VTCompressionSession` and force an IDR. If it recurs `ENCODER_STALL_ESCALATE` times, escalate to a full reconnect.

## Decoder recovery ladder (Display)

VideoToolbox errors are handled by kind, not uniformly (a common bug is rebuilding the session when you only needed a keyframe):

| condition | action |
|-----------|--------|
| `kVTVideoDecoderReferenceMissingErr` | send `REQUEST_IDR`; do **not** rebuild the session |
| `requiresFlushToResumeDecoding == true` (macOS 15+) | `flush()` the renderer, then continue; if it persists, send `REQUEST_IDR` |
| `kVTVideoDecoderBadDataErr` / `kVTVideoDecoderMalfunctionErr` / `kVTInvalidSessionErr` | `VTDecompressionSessionInvalidate` + recreate with a fresh `CMFormatDescription` from the latest VPS/SPS/PPS, then `REQUEST_IDR` |
| repeated rebuilds > `DECODER_REBUILD_LIMIT` | escalate to full reconnect |

## Sleep / wake {#sleepwake}

Register for `NSWorkspace.willSleepNotification` / `didWakeNotification` and the `screensDidSleep/Wake` variants.

- **On local sleep:** send `PAUSE{reason:"sleep"}`, pause capture/encode (source) or decode (display), and stop counting heartbeat misses against the peer (the peer will also be told via PAUSE). Enter `paused`.
- **On wake:** the source **recreates the virtual display if it was invalidated** (do not assume it survived — verified fragile across sleep/wake), rebuilds capture+encode, sends `RESUME`, forces an IDR. The display rebuilds its decoder and re-enters `streaming` on the first frame.
- A `PAUSE` from the peer suppresses the death timers for up to `PAUSE_MAX` (e.g. 90 s); beyond that, treat as dead and reconnect.

## Virtual-display lifecycle & crash safety

- The virtual display is owned by the helper subprocess (Phase 1). If the main app crashes, the helper detects the broken channel and **destroys the display** (no phantom monitor).
- On launch, the app checks a PID/lock file and **cleans up any orphaned helper/display** from an unclean previous exit.
- **Mode-list guardrail:** `CGVirtualDisplayMode` lists are kept minimal (the requested mode + at most a couple of standard fallbacks) and default to **60 Hz** to avoid the documented `WS::Displays::GenerateModeListForDisplay()` assertion that crashes WindowServer. Never expose >60 Hz virtual modes in v1.
- Register `CGDisplayRegisterReconfigurationCallback` and the `CGVirtualDisplay` termination handler to react to system-initiated teardown.

## Latency measurement (correct)

Never `Date()`. RTT is computed from `PING`/`PONG` on a single monotonic clock (see [02 § PING/PONG](02-protocol.md#ping--pong-0x30--0x31)). The HUD shows `RTT/2` as the one-way estimate plus decode/present timing measured locally on the Display. Glass-to-glass is *estimated* (capture→encode local time + one-way + decode→present local time), clearly labeled as an estimate.

## Constants {#constants}

Session/timing constants (in `SidewireCore`). Protocol constants are in [02 § Constants](02-protocol.md#constants).

| name | value | rationale |
|------|-------|-----------|
| `HEARTBEAT_INTERVAL` | 500 ms | frequent enough for ~1.5 s detection, cheap |
| `HEARTBEAT_TIMEOUT` | 2500 ms | ~5 missed PONGs |
| `HEARTBEAT_MISS_LIMIT` | 5 | derived |
| `TCP_KEEPALIVE_IDLE` | 2 s | LAN |
| `TCP_KEEPALIVE_INTERVAL` | 1 s | LAN |
| `TCP_KEEPALIVE_COUNT` | 3 | ~few s backstop |
| `CONNECTION_DROP_TIME` | 5 s | **finite send timeout — fixes the hang** |
| `VIABILITY_DEBOUNCE` | 2500 ms | survive brief flaps |
| `NO_FRAME_DIM` | 750 ms | receiver shows "reconnecting" |
| `NO_FRAME_TEARDOWN` | 3000 ms | receiver tears down |
| `ENCODER_WATCHDOG` | 1000 ms | frames-in-no-output |
| `ENCODER_STALL_ESCALATE` | 3 | then full reconnect |
| `DECODER_REBUILD_LIMIT` | 3 | then full reconnect |
| `RECONNECT_BACKOFF` | [0.25, 0.5, 1, 2, 4] s, cap 5 s | + up to ±20% jitter |
| `RECONNECT_MAX_ATTEMPTS` | ∞ for network loss; small for fatal | RDP-like persistence |
| `PAUSE_MAX` | 90 s | peer-sleep grace |
| `GETSHAREABLE_TIMEOUT` | 5000 ms | `SCShareableContent` can hang |

## Failure modes {#failure-modes}

The complete table this subsystem must satisfy. Each row is an acceptance target for Phase 1.

| # | Failure | Detect | Recover |
|---|---------|--------|---------|
| 1 | **Thunderbolt cable pulled** mid-stream | `NWPathMonitor` `.unsatisfied` <1 s; heartbeat miss ~1.5 s; `connectionDropTime` fails the blocked send at 5 s | keep virtual display alive; "Cable unplugged — reconnecting"; re-resolve via Bonjour; backoff; IDR on return; **never block main thread** |
| 2 | **Half-open TCP** (peer vanished, no FIN/RST) | app heartbeat (macOS TCP default ~2 h is useless) | declare dead, `forceCancel()`, rebuild + idempotent resume |
| 3 | **Receiver freeze** (frozen last frame) | no-frame watchdog decoupled from cadence | 750 ms dim + spinner; 3 s teardown + reconnect |
| 4 | **Silent encoder/GPU hang** (control alive, video frozen) | encoder-stall watchdog (in) + receiver no-frame watchdog (out) | recreate `VTCompressionSession`; receiver `REQUEST_IDR`; escalate if recurring |
| 5 | **Decoder malfunction** (net healthy) | VT error codes + `requiresFlushToResumeDecoding` | recovery ladder above |
| 6 | **SCK stall / static-screen misread** | distinguish `.idle` (skip) from `didStopWithError` | never treat "no frame" as dead on source; rebuild `SCStream` on real error; release `IOSurface` promptly |
| 7 | **Sleep/wake** (either side) | `NSWorkspace` notifications + heartbeat gap + PAUSE | recreate virtual display if needed; rebuild pipelines; IDR; never assume survival |
| 8 | **Wi-Fi roam / VPN steals route** | path change; link-local deprioritized | debounce 2.5 s; bind `NWConnection` to required interface so VPN can't hijack the TB path; migrate or rebuild+resume |
| 9 | **Screen Recording permission revoked** mid-session (Sequoia monthly re-prompt) | SCStream errors and/or a run of all-black frames | surface "permission revoked" + deep link; pause + re-request |
| 10 | **Packet-loss corruption** (Wi-Fi) | NAL gap via `seq`; decode discontinuity | `LTR_ACK`-driven `ForceLTRRefresh` (small) not full IDR; never retransmit stale video |
| 11 | **Port in use / stale listener after crash** | `NWListener` bind failure; TIME_WAIT | advertise ephemeral Bonjour port (not fixed 5005); orphan cleanup on launch |
| 12 | **Tahoe HiDPI ~20 fps regression** | measured fps far below target on macOS 26 with HiDPI | fall back to non-HiDPI mode; surface a note; (see [00 C7]) |
