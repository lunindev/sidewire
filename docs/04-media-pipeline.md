# 04 — Media Pipeline

Concrete settings for capture, encode, decode, present, virtual display, and input. Values verified current for 2026 (macOS 15/26, Apple Silicon M4 + Intel). The current app's pipeline already works end-to-end; the changes here are targeted improvements (420v zero-copy, LTR recovery, `requiresFlush` handling, energy) plus the virtual-display helper.

## Virtual display {#virtual-display}

Owned by `SidewireDisplayHelper` (Phase 1); wrapped by `CGVirtualDisplayBridge`. Only the **Source** creates one.

- **API:** private `CGVirtualDisplay` / `CGVirtualDisplayDescriptor` / `CGVirtualDisplaySettings` / `CGVirtualDisplayMode`, accessed via the existing reverse-engineered header (`Private/CGVirtualDisplayPrivate.h`). Instantiate through `NSClassFromString` with nil-checks and an `@available`/`ProcessInfo` OS gate; if a class is missing (future macOS), fail to a clear error + mirror-only fallback rather than crash.
- **Why a helper subprocess:** `CGVirtualDisplay` registers reliably only from a clean process context (verified — Lumen's `vd_helper`). The helper also gives crash isolation and clean orphan teardown ([03 § lifecycle](03-reliability.md#virtual-display-lifecycle--crash-safety)). Phase 0 may create it in-process to get moving; Phase 1 moves it to the helper behind the same `VirtualDisplayController` async API.
- **Sizing:** dimensions come from the Display's `DISPLAY_INFO` (native pixels) or a user-picked resolution. Set `maxPixelsWide/High` and a single primary `CGVirtualDisplayMode`. Keep `sizeInMillimeters` plausible for the DPI.
- **HiDPI:** request a `hiDPI = 1` settings object and select a Retina mode (`pixelWidth > width`), as the current code does in `forceHiDPIMode`. **Tahoe caveat:** HiDPI virtual displays can drop to ~20 fps on macOS 26 (unresolved). Provide a **non-HiDPI fallback** and, if fps is far below target on Tahoe with HiDPI on, auto-suggest it. Track via [03 failure #12](03-reliability.md#failure-modes).
- **Mode-list guardrail:** supply a **minimal** mode list (the target mode + at most a couple of standard fallbacks) and **cap at 60 Hz**. Long or high-refresh mode lists crash WindowServer (`GenerateModeListForDisplay` assertion; 240 Hz scroll crash). Non-negotiable in v1.
- **Force extend, not mirror:** use `SLSConfigureDisplayEnabled` (SkyLight, private — same pattern as Lumen) to ensure the virtual display is an *extended* desktop, not mirrored. Extended is the whole point and also side-steps the mirror-specific sleep/wake and HiDPI issues.
- **Lifecycle:** honor `terminationHandler`; on any recreation, resize by destroy→recreate with a short delay (as today's `recreate`), and re-fetch shareable content afterward.

## Capture (ScreenCaptureKit) {#capture}

`ScreenCapture.swift`, delivering on a dedicated `DispatchQueue`. The Source captures **its own virtual display** (an ordinary `SCDisplay` in `SCShareableContent`).

`SCStreamConfiguration`:

| field | value | why |
|-------|-------|-----|
| `pixelFormat` | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (`420v`) | **change from today's `32BGRA`.** The captured `IOSurface` goes straight into the HEVC/H.264 encoder with no RGB→YUV conversion — less CPU/GPU/energy on the M4 Max, lower latency. |
| `width` / `height` | virtual display pixel dims | match encode dims |
| `minimumFrameInterval` | `CMTime(1, fps)` (e.g. 1/60) | ceiling on fps; SCK only delivers on change, so idle screens cost ~nothing. (Optionally add ~10% headroom, e.g. `1/66`, per OBS to reduce SCK drops.) |
| `queueDepth` | `5` | 3–8 recommended; 5 balances latency vs stall resistance |
| `showsCursor` | `true` | remote-control app wants the pointer baked in |
| `capturesAudio` | `false` (v1) | audio is reserved (`0x11`); add later without a wire break |
| `colorSpaceName` | `CGColorSpace.sRGB` explicitly | don't let the receiver guess; SDR default |

Frame handling:
- Only forward `SCFrameStatus.complete` frames. **`.idle` (static screen) yields no new surface — skip it, never treat it as an error or as liveness.** This is load-bearing for [03](03-reliability.md).
- Release each `IOSurface`/`CVPixelBuffer` promptly after handing it to the encoder (within `minimumFrameInterval × (queueDepth − 1)`), or SCK's surface pool exhausts.
- Wrap `SCShareableContent.getShareableContent` in a `Task` with `GETSHAREABLE_TIMEOUT` (5 s) — it is documented to hang; a hang here is a prime suspect for the current freezes.
- **Static-screen keep-alive:** when no `.complete` frame has arrived for ~1 s, the Source sends a periodic refresh (re-send the last encoded keyframe, or force a small IDR) so the Display's no-frame watchdog isn't tripped by a legitimately static screen. Heartbeat still flows regardless.

## Encoder (VideoToolbox) {#encoder}

`VideoEncoder.swift`. `VTCompressionSession`, codec chosen by negotiation (HEVC default; H.264 if negotiated).

Encoder spec (at creation):
- `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true` — the low-latency hardware path (Apple-Silicon-only for HEVC; works for H.264 more broadly). Verified current for 2026.

Session properties:

| property | value |
|----------|-------|
| `RealTime` | `true` |
| `ProfileLevel` | HEVC `Main_AutoLevel` / H.264 `High_AutoLevel` |
| `AllowFrameReordering` | `false` (no B-frames) |
| `ExpectedFrameRate` | negotiated fps |
| `AverageBitRate` | adaptive (start 30 Mbps, range 5–50) |
| `DataRateLimits` | a hard ceiling around the adaptive target |
| `MaxKeyFrameInterval` | **bounded but long** (e.g. 5 s) — rely on LTR, not frequent IDRs |
| `MaxAllowedFrameQP` | cap quality under congestion (hold fps) |
| `EnableLTR` | `true` — enables the recovery loop below |

**LTR recovery loop** (replaces forced-keyframe recovery; avoids the `max_ref_frames=1` IDR-inflation trap):
1. The encoder periodically marks frames as long-term references; each carries an ack token in its sample attachments → sent in the `VIDEO` message's `ltrToken` with flag bit 1.
2. The Display echoes tokens it actually received/decoded via `LTR_ACK` ([02](02-protocol.md#control-messages)).
3. On loss (Display sends `REQUEST_IDR` or the source sees `FEEDBACK` loss), the source prefers `kVTEncodeFrameOptionKey_ForceLTRRefresh` against a **known-acknowledged** token — emitting a small LTR-P (flag bit 2) — instead of a full IDR. Full IDR only when no acknowledged LTR exists (e.g. first frame, or after a long gap).

Keyframes still emit VPS/SPS/PPS parameter sets inline (as today's `extractParameterSets`).

**Adaptive bitrate (v1, simple).** Replace the current `pendingSends` heuristic with a controller fed by `FEEDBACK` (loss%, decode queue, presented fps) + local send-queue depth + RTT trend:
- sustained loss or rising RTT/queue → cut `AverageBitRate` (e.g. ×0.7) and/or raise `MaxAllowedFrameQP`, then reduce target fps as a last resort;
- sustained clear → ramp `AverageBitRate` up cautiously (e.g. ×1.15) toward the ceiling.
Full delay-gradient (GCC) control is a Phase 2 refinement, only if Wi-Fi needs it. On Thunderbolt this rarely engages.

**Sender energy budget.** The M4 Max (Source) must stay light:
- 420v zero-copy capture→encode (no color convert, no pixel copy);
- skip `.idle` frames and stop emitting encoded frames on a static screen (send the periodic keep-alive instead) — a still desktop should draw near-zero encode power;
- encode on the capture delivery queue; avoid extra actor hops on the hot path;
- verify with `powermetrics` in Phase 2 and show a live glass-to-glass estimate in the HUD.

## Decoder (VideoToolbox) {#decoder}

`VideoDecoder.swift`. `VTDecompressionSession` built from the parameter sets in each keyframe (as today). Additions:
- Parse Annex-B NALs and rebuild the `CMFormatDescription` on parameter-set change (existing logic ports directly).
- **Honor `requiresFlushToResumeDecoding`** (macOS 15+, on `AVSampleBufferVideoRenderer`): after any interruption the renderer won't decode until `flush()` is called — miss it and video freezes permanently after one glitch. Wire it into the [decoder recovery ladder](03-reliability.md#decoder-recovery-ladder-display).
- Follow the recovery ladder for VT error codes (don't rebuild on `ReferenceMissingErr`; do rebuild on malfunction/bad-data/invalid-session).
- Decode asynchronously (`_EnableAsynchronousDecompression`), set `DisplayImmediately` on keyframes.

## Present {#present}

`VideoPresenter.swift`, `@MainActor`.

- **v1:** `AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_DisplayImmediately = true` on every buffer (the current approach). Simple; "good" latency. Flush on discontinuity; on `status == .failed`, flush and request an IDR.
- Add a small **adaptive jitter buffer** (1–2 frames); under sustained backlog, **drop to the newest** frame rather than draining a queue.
- **Phase 2 optional:** a `VTDecompressionSession → CAMetalLayer` present path removes the ~1 extra frame `AVSampleBufferDisplayLayer` buffers (moonlight-qt's `VT_FORCE_METAL` finding). Only build this if measurement shows the frame matters; it's an optimization, not a requirement.

## Input {#input}

Unchanged mechanics from today, two changes: **binary 32-byte events** ([02 § INPUT](02-protocol.md#input-0x20)) instead of JSON, and **pairing-gated injection**.

- **Capture (Display):** `InputCapture.swift`, `NSEvent` local monitor. Normalize `(x,y)` to 0..1 within the content view (existing logic). Keep the current escape hatches: `Cmd`-combos and `Esc` (keyCode 53) are *not* forwarded so the user can always control the Display Mac and exit immersive mode.
- **Inject (Source):** `InputInjector.swift`, `CGEvent`. Map normalized coords onto the virtual display's `CGDisplayBounds` (existing `mapToDisplay`). **Refuse injection unless the peer is paired** ([05](05-security-and-pairing.md)) — this is the difference between "screen share" and "handed a stranger my keyboard."
- Requires **Accessibility** permission on the Source (for `CGEvent` posting) in addition to Screen Recording.

## Summary of concrete changes vs today

| area | today | Sidewire |
|------|-------|----------|
| capture pixel format | `32BGRA` (converts to YUV) | `420v` zero-copy |
| loss recovery | force keyframe | LTR-P against acknowledged token; IDR only as fallback |
| decoder resume | — | honor `requiresFlushToResumeDecoding` |
| adaptive bitrate | `pendingSends` count | `FEEDBACK` + queue + RTT controller |
| input encoding | JSON per event | 32-byte binary record |
| virtual display | in-process | helper subprocess (Phase 1), mode-list guardrail, forced extend |
| static screen | encodes/streams anyway | skip `.idle`, periodic keep-alive, near-zero power |
