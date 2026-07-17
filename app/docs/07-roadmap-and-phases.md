# 07 — Roadmap & Phases

Implement in this order. Each phase is independently shippable-to-yourself and ends with **acceptance criteria** that are physically verified on the real **M4 Max (Source) ↔ Intel i9 (Display)** pair — nothing is "done" on code review alone. Phases are sized so the app is usable after Phase 1 and trustworthy after Phase 3.

Scope reminder ([00 C1]): **Mac ↔ Mac only.** No Windows, QUIC, or mobile work in this roadmap. The protocol is versioned so that door stays open at zero present cost.

---

## Phase 0 — Foundation: one universal app + protocol skeleton

**Goal.** Collapse `SenderApp` + `ReceiverApp` into a single non-sandboxed Universal 2 SwiftUI app named **Sidewire** with a role picker, and stand up the versioned protocol package. End-to-end streaming works through the new app on both machines (still in-process virtual display, no reliability work yet).

**Tasks.**
- [ ] New single Xcode project `Sidewire`; app target Universal 2 (`arm64 x86_64`), non-sandboxed, hardened runtime, `LSUIElement`, macOS 14 deployment target. Rename bundle id to the final `com.sidewire.*` (fix it now, never change — TCC keys on it).
- [ ] `Role` enum + persistence; role-picker window; route to `SourceController` / `DisplayController`.
- [ ] `SidewireProtocol` package: `FrameHeader` (12-byte), message catalog, JSON+binary codecs, HELLO/HELLO_ACK/CONFIG/DISPLAY_INFO, unknown-message skipping. Unit tests for round-trip + skip + version rules.
- [ ] `SidewireCore` package: `Transport` protocol + a `NWConnection`/`NWListener` TCP implementation; a minimal `Session` that does connect → handshake → stream (no reconnect yet). Fake `Transport` for tests.
- [ ] Port `ScreenCapture`, `VideoEncoder`, `VideoDecoder`, `VideoPresenter`, `VirtualDisplay` (in-process), `InputCapture`, `InputInjector` into `Media/`+`Input/`. Switch capture to **420v**; switch input to **binary 32-byte** events. Wire the pipelines through the new `Session`.
- [ ] Menu-bar surface (basic): status, discovered devices, connect/disconnect. Bonjour service `_sidewire._tcp`, ephemeral port.

**Acceptance.**
- One app, launched on both Macs; pick Source on the M4, Display on the i9.
- Source auto-discovers the Display; one connect starts a virtual display and streams it; the Display shows the extended desktop fullscreen and forwards mouse/keyboard.
- Works over both Wi-Fi and a direct Thunderbolt cable.
- Protocol unit tests green; a newer-minor peer stub is tolerated (skips unknown messages).

**Risks.** Merging two codebases surfaces hidden global state; the private-class bridge must be tested on **both** Apple Silicon and Intel; every dependency must be universal.

---

## Phase 1 — Reliability: kill the hang, the freeze, the half-open

**Goal.** Make reconnection rock-solid across cable pull, sleep/wake, interface change, and freeze. This is the owner's #1 pain and the product's differentiator. Implements all of [03](03-reliability.md).

**Tasks.**
- [ ] App-level `PING`/`PONG` heartbeat (500 ms) with 2.5 s dead-peer timeout; single-clock RTT.
- [ ] All socket I/O async via `NWConnection`, off the main thread; `NWProtocolTCP.Options` keepalive (2/1/3) + **`connectionDropTime = 5`** + `noDelay`.
- [ ] `NWPathMonitor` + per-connection `viabilityUpdateHandler` with `VIABILITY_DEBOUNCE`; explicit `Session` **state machine** (idle→…→streaming→degraded/reconnecting/paused/failed) with exponential backoff + jitter; `forceCancel()` on death.
- [ ] Reconnect **re-resolves via Bonjour** (not cached IP) → works in discovery mode; interface binding so a VPN/Wi-Fi can't hijack the Thunderbolt link; last-known-good IP fallback.
- [ ] Receiver **no-frame watchdog** decoupled from cadence (750 ms dim / 3 s teardown); source **encoder-stall watchdog**; **static-screen keep-alive**; skip `.idle`.
- [ ] **Decoder recovery ladder** incl. `requiresFlushToResumeDecoding`; `REQUEST_IDR` control message + source `ForceKeyFrame`; LTR-ack plumbing (encoder LTR on, `LTR_ACK`, `ForceLTRRefresh`).
- [ ] **Virtual-display helper subprocess** (`SidewireDisplayHelper`): move creation out of the main process; mode-list guardrail + 60 Hz cap; `SLSConfigureDisplayEnabled` forced-extend; orphan cleanup + PID/lock file + `atexit`/`SIGTERM` teardown.
- [ ] Sleep/wake handling via `NSWorkspace` (PAUSE/RESUME; recreate virtual display on wake).
- [ ] Visible reconnection UI states.

**Acceptance (each verified physically).**
- **Cable pull:** yank the Thunderbolt cable mid-stream → Display shows "reconnecting" within ~1.5 s, **no hang**; replug → full restore within ~3 s; no phantom virtual display remains; the M4's UI never freezes.
- **Half-open:** kill the Display app's process (SIGKILL) → Source detects death within ~2.5 s and enters reconnecting, not a multi-minute stall.
- **Freeze:** simulate a stalled decoder → receiver dims + reconnects rather than showing a frozen frame forever.
- **Sleep/wake:** sleep the Display, wake it → session resumes automatically; sleep the Source, wake it → virtual display recreated, stream resumes.
- **Bonjour reconnect:** all of the above recover in auto-discover mode, not just manual-IP.
- **No orphans:** force-crash the Source → helper tears the virtual display down; relaunch cleans any orphan.

---

## Phase 2 — Performance & latency

**Goal.** Minimize Source energy on the M4 Max and reach a Luna-class latency envelope (~<30 ms Wi-Fi, ~16 ms Thunderbolt) with honest single-clock measurement.

**Tasks.**
- [ ] Confirm zero-copy 420v capture→encode; prompt `IOSurface` release; `queueDepth`/`minimumFrameInterval` tuning.
- [ ] Full HEVC-LL config (DataRateLimits, MaxAllowedFrameQP, bounded MaxKeyFrameInterval) with the LTR loop as the primary recovery (validate LTR-P vs IDR sizes).
- [ ] Adaptive bitrate controller driven by `FEEDBACK` + queue + RTT (replaces `pendingSends`).
- [ ] Receiver jitter buffer (1–2 frames, drop-to-newest).
- [ ] **Optional** Metal/`CAMetalLayer` present path — build only if measurement shows the ~1-frame `AVSampleBufferDisplayLayer` buffering matters.
- [ ] `powermetrics`-verified Source energy numbers; live glass-to-glass estimate in the HUD.
- [ ] **Tahoe check:** measure HiDPI fps on macOS 26; if the ~20 fps regression bites, validate the non-HiDPI fallback path.

**Acceptance.** Static desktop: Source encode power near-idle. Active use: measured one-way latency in target envelope over Thunderbolt; no visible stutter over 5 GHz Wi-Fi at 1440p60; LTR recovery visibly smoother than forced-IDR (no bitrate spike on loss).

---

## Phase 3 — Security & pairing

**Goal.** Close the open-LAN remote-control hole before any exposure beyond a fully trusted network. Implements [05](05-security-and-pairing.md).

**Tasks.**
- [ ] TLS 1.3 over `NWConnection` with self-signed certs + public-key pinning (`sec_protocol_options_set_verify_block`).
- [ ] First-connect **PIN pairing** via SPAKE2 (fallback TLS-PSK from PIN via HKDF); PIN never on the wire; QR option.
- [ ] Keychain `TrustStore`; paired peers reconnect with no prompt; "Forget this Mac".
- [ ] **Input-injection gate:** refuse `CGEvent` from any unpaired peer; refuse connections past `pairing` without success. Rate-limit PIN attempts.

**Acceptance.** A second, unpaired Mac on the same LAN cannot connect or inject input. Pairing with the correct PIN succeeds and persists; a wrong PIN fails without leaking; a changed peer key triggers a re-pair warning. Traffic is TLS (verify with a packet capture — no plaintext frames).

---

## Phase 4 — UX polish & permission onboarding

**Goal.** The polished "Apple system utility" experience with a permission gauntlet that actually works. Implements [06](06-ux-and-onboarding.md).

**Tasks.**
- [ ] Full `MenuBarExtra(.window)` surface: AirPlay-style device list, status dots, opt-in HUD.
- [ ] Permission checklist: Screen Recording via `CGRequestScreenCaptureAccess` + **relaunch step**; Accessibility via `AXIsProcessTrustedWithOptions`; Local Network with early prompt + illustrated no-deep-link directions.
- [ ] Immersive receiver: auto-hiding control bar, multi-path exit, "Press Esc to exit" toast, in-view reconnection labels.
- [ ] Resolution/HiDPI preset menu driven by DISPLAY_INFO ("Match Display", 1080p/1440p/2.5K, Retina toggle).
- [ ] Sequoia monthly re-auth + mid-session revocation detection (black-frame inference) with clear messaging.
- [ ] Diagnostics export.

**Acceptance.** A fresh Mac with no permissions can be taken from first launch to streaming using only the in-app guidance (no docs). Granting Screen Recording/Accessibility drives a clean relaunch, not a broken half-state. Immersive mode never traps the user.

---

## Phase 5 — Distribution: signed, notarized, auto-updating

**Goal.** A public-ready, signed, notarized, auto-updating universal build with a stable identity. Implements [08](08-build-and-distribution.md).

**Tasks.**
- [ ] Developer ID Application signing (the owner has the cert); hardened-runtime entitlements; **no sandbox**.
- [ ] CI (GitHub Actions): archive → export (developer-id) → `create-dmg` → `notarytool submit --wait` → `stapler staple` → `spctl` verify.
- [ ] Sparkle 2 auto-update (EdDSA), appcast + DMG on GitHub Releases; `CFBundleVersion` bumping; no `codesign --deep`.
- [ ] Permissive license (MIT/Apache-2.0); a simple landing page positioning ("free Mac-to-Mac wireless *and* Thunderbolt second display").

**Acceptance.** A notarized DMG installs and launches on a clean Mac (Gatekeeper passes offline — stapled). TCC grants survive a Sparkle update (stable identity). `spctl -a -t exec -vv` passes.

---

## Out of scope (deliberately deferred)

Not in this roadmap; revisit only if actually needed:
- **Windows/Linux peer** — the versioned protocol makes it a from-spec reimplementation later; no code now.
- **QUIC transport** — behind the `Transport` interface; only if Wi-Fi loss proves inadequate.
- **Mobile (phone/tablet as display)** — best path is a WebRTC/browser receiver profile; a post-launch research spike with measured latency, not production.
- **Audio** — message type `0x11` reserved; add Opus later without a wire break.
- **Multi-display / >1 virtual monitor**, HDR, 10-bit — future.

## Risk register {#risk-register}

| risk | severity | mitigation |
|------|----------|------------|
| Private `CGVirtualDisplay` breaks on a macOS update | high | thin abstraction + `NSClassFromString` nil-checks + OS gate + mirror-only/clear-error fallback; test every macOS beta |
| **Tahoe HiDPI ~20 fps regression** (live, unresolved) | high | non-HiDPI fallback mode; forced-extend (not mirror); measure on macOS 26 in Phase 2 |
| WindowServer crash from bad mode lists / high refresh | high | minimal mode lists, 60 Hz cap (hard rule) |
| Heartbeat/keepalive tuning: fast cable-pull detection vs Wi-Fi false positives | medium | empirical tuning on the real M4↔i9 pair; debounced viability |
| Apple ships Mac-to-Mac Sidecar / Universal-Control-with-video | medium | differentiator is reliability + Thunderbolt + polish, not the display trick |
| TCC grants lost on identity change | medium | one stable Developer ID + bundle id for the product's life |
| SPAKE2 library availability in Swift | low | TLS-PSK-from-PIN fallback documented ([05](05-security-and-pairing.md)) |
