# 00 — Review & Decisions

This document is an independent critical review of the earlier rebuild plan, plus the final decisions that govern the rest of the spec. Where a decision differs from the earlier plan, the difference and its reason are called out explicitly. Decisions are written ADR-style: **Decision → Why → Alternatives rejected → Consequences.**

Two constraints from the owner shape everything below:

1. **Scope is Mac ↔ Mac only, now.** Windows and mobile are explicitly *not* in this plan. This is the single biggest change from the earlier plan and it removes a large amount of speculative complexity.
2. **Personal-first, but publishable.** The owner has an Apple Developer ID and will sign & notarize. The app should be shippable to the public later without rearchitecting, but no feature is added *solely* to serve a hypothetical public/other-platform future.

---

## Part A — Verdict on the earlier plan

The earlier plan was, on the whole, correct and well-researched. Its core thesis — *keep the capture/virtual-display/encode core, and put all the new engineering into reliability, security, and polish* — is right and is confirmed by the 2026 verification pass. The following holds up and is **adopted unchanged**:

- Keep `CGVirtualDisplay` + ScreenCaptureKit + VideoToolbox HEVC. Verified still the only viable path in 2026; no public replacement exists; notarization does not flag it.
- One universal, non-sandboxed, Developer-ID-notarized SwiftUI app; role chosen at launch.
- Stay in **Swift**. (With cross-platform dropped, there is now *zero* argument for a Rust/C++ core — see D1.)
- **TCP + TLS** transport for v1; HEVC-low-latency with **H.264 fallback**; AV1 is out (no hardware encoder on M4).
- Application-level **heartbeat** + `NWPathMonitor` + tuned keepalive as the fix for the cable-pull hang.
- Receiver **no-frame watchdog decoupled from video cadence** (a static screen legitimately produces zero frames).
- **Menu-bar-first** UI with an immersive fullscreen receiver.
- Security (TLS + PIN pairing + key pinning) is a real prerequisite for public release, because the reverse input channel grants remote *control*, not just viewing.

Where the earlier plan was **over-scoped, under-specified, or slightly wrong**, this review corrects it. Those corrections are Part B.

---

## Part B — Corrections and sharpenings (what this review changes)

### C1 — Cut cross-platform, QUIC-now, and mobile from the plan entirely
The earlier plan carried a lot of "Windows-readiness": a language-neutral protocol spec as "the durable asset," QUIC as a near-term transport, a WebRTC/mobile profile designed in early. With scope now Mac-only, all of that is speculative weight.

- **Kept (cheap):** the protocol is *versioned* and uses length-prefixed, type-tagged messages with reserved ranges so it can evolve. That's just good hygiene and costs nothing.
- **Dropped (expensive, no near-term payoff):** the formal cross-platform spec document, QUIC transport, the WebRTC/WASM profile, any IddCx/Windows design. If a Windows peer is ever funded, the versioned protocol is enough to reimplement against; we do not pre-build for it.

### C2 — The virtual-display helper subprocess is *required*, not just defense-in-depth
The earlier plan treated the XPC/helper subprocess as crash-isolation insurance. The verification pass found something stronger: **Lumen (a shipping 2026 app) had to create the virtual display in a `vd_helper` subprocess because `CGVirtualDisplay` fails to register properly when created inside a "dirty" host process** — TCC/WindowServer registration wants a clean process context. So the helper is a reliability *requirement*, not a nicety.

Sequencing decision: implement in-process first in Phase 0 (fastest path to a working unified app, matches today's code), and move creation into a bundled helper subprocess in **Phase 1**, behind a clean async boundary designed from day one so the move is mechanical. See [04 § Virtual Display](04-media-pipeline.md#virtual-display).

### C3 — Specify the LTR acknowledgment loop concretely
The earlier plan mentioned LTR (long-term reference frames) but left it vague. The verification pass confirmed this is *the* resilience mechanism and that the naive alternative (forcing a keyframe to recover) is a documented trap (`max_ref_frames=1` → every frame becomes an IDR → multi-× bitrate inflation). This spec makes LTR a **protocol-level** feature: the sender tags LTR frames with a token; the receiver echoes acknowledged tokens; on loss the sender emits an LTR-P against a known-good frame instead of a full IDR. See [02 § Control messages](02-protocol.md#control-messages) and [04 § Encoder](04-media-pipeline.md#encoder).

### C4 — Elevate two easy-to-miss correctness fields
Both are cheap to add and cause catastrophic, hard-to-debug failures if missed:

- **`connectionDropTime ≈ 5 s`** on `NWProtocolTCP.Options`. This is the send-side retransmit timeout. Without it, a `send()` to a peer whose cable was pulled retries *forever* — this is a direct contributor to the current hang. It is the single most important networking field for "peer vanished mid-stream," because a video stream is almost always mid-send.
- **`requiresFlushToResumeDecoding`** on the receiver's renderer (macOS 15+). After any decode interruption the renderer refuses to decode again until you `flush()`. Miss it and a single glitch freezes the video *permanently*. Wire it into the decoder recovery ladder.

### C5 — Right-size the present path and congestion control
The earlier plan leaned toward a Metal/`CAMetalLayer` present path and a full GCC-style congestion controller. Both are premature for v1:

- **Present:** ship `AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_DisplayImmediately` (simple, already in use, "good" latency). The Metal path shaves ~1 frame of hidden buffering but is a measurable optimization, not a v1 requirement. It moves to Phase 2, gated on actually measuring that the extra frame matters.
- **Congestion control:** for a Thunderbolt-primary, lossless-link app, a full delay-gradient GCC controller is overkill for v1. Start with a simple controller driven by RTT trend + send-queue depth + receiver-reported loss, adjusting `AverageBitRate` and `MaxAllowedFrameQP`. Full GCC is a Phase 2 refinement if Wi-Fi demands it.

### C6 — Binary-pack input events (the earlier plan kept JSON)
The current code JSON-encodes every input event, including `mouseMoved` storms. That is wasteful CPU/allocation on the hot path and on the sender we're trying to keep light. This spec defines a **fixed 32-byte binary layout** for input events. See [02 § INPUT](02-protocol.md#input).

### C7 — Name the #1 product risk honestly
Everything rests on a private API with a *live, unresolved 2026 regression*: on macOS 26 (Tahoe), HiDPI virtual displays can drop to ~20 fps. Mitigations are designed in (non-HiDPI fallback mode, a mode that captures the virtual display without mirroring, mandatory test-on-Tahoe before any release). This risk is tracked in [03 § Failure modes](03-reliability.md#failure-modes) and [07 § Risks](07-roadmap-and-phases.md#risk-register). It is not a reason to abandon the approach — there is no alternative — but it must be visible.

---

## Part C — The decisions

### D1 — One universal Swift app; no Rust/C++ core
**Decision.** A single Xcode project producing one non-sandboxed, hardened-runtime, Universal 2 (arm64 + x86_64) SwiftUI app targeting macOS 14+. Role (Source / Display) chosen at launch and remembered. All logic in Swift; protocol/session logic extracted into local Swift packages for testability.

**Why.** Every latency-critical capability is Apple-native and Swift-first: ScreenCaptureKit, `CGVirtualDisplay`, VideoToolbox, `CGEvent`, `AVSampleBufferDisplayLayer`, Network.framework. Swift Concurrency (actors) fits the "many independent liveness sources feeding one state machine" shape cleanly. With cross-platform dropped, there is no code to share with a non-Apple peer, so a Rust/C++ core would only add FFI friction with no payoff. **Will it scale?** Yes — the ceiling here is macOS APIs and the hardware encoder, not the language; Swift imposes no relevant limit for a two-machine LAN media pipeline.

**Alternatives rejected.** Rust/C++ shared core (no payoff without a second platform; still needs a Swift shim for the private display API). Electron/Tauri (webview decode-to-canvas latency and per-webview codec bugs — disqualifying for low-latency video). Keeping two apps (fails the unification goal, doubles maintenance).

**Consequences.** No Mac App Store (private API + input injection). Distribution is Developer ID + notarization only (the owner has the cert). See [08](08-build-and-distribution.md).

### D2 — Keep `CGVirtualDisplay`, isolate it, guardrail it
**Decision.** Create the extended display via the private `CGVirtualDisplay` family, wrapped behind a thin Swift bridge instantiated with `NSClassFromString` + runtime nil-checks + OS-version gating. Create it **in a bundled helper subprocess** (Phase 1) for reliable registration and crash isolation. Keep `CGVirtualDisplayMode` lists **small** and default to **60 Hz** to avoid the WindowServer mode-list assertion crash. Provide a graceful mirror-only / clear-error fallback if the symbols ever vanish.

**Why.** Verified: only viable path in 2026, used by every shipping competitor, notary-safe. The helper subprocess is what Lumen needed for registration. The mode-list guardrail and 60 Hz default avoid the two documented WindowServer crash classes.

**Alternatives rejected.** DriverKit/CoreMediaIO (yields a virtual *camera*, not a display macOS can extend onto). In-process-forever creation (registration flakiness; couples display lifetime to app crashes). High refresh modes (240 Hz virtual display crashes WindowServer under scroll load — documented).

**Consequences.** A private-API risk surface that must be tested against every macOS major/point release; mitigated by the abstraction boundary + fallback. The Tahoe HiDPI regression (C7) is the acute instance.

### D3 — TCP + TLS transport for v1, behind a thin transport interface
**Decision.** `NWConnection` over TCP with `noDelay`, tuned keepalive (idle 2 s / interval 1 s / count 3), and `connectionDropTime = 5 s`, wrapped in TLS 1.3. Put it behind a small `Transport` protocol so a future QUIC implementation is a drop-in, but do **not** implement QUIC now.

**Why.** On a lossless direct Thunderbolt/LAN link, TCP head-of-line blocking never triggers, so TCP is the simplest low-latency option and is what the app already speaks. TLS gives the missing encryption for free. QUIC's only real win (unreliable datagrams over lossy Wi-Fi) doesn't justify its immaturity cost for a Mac-only v1.

**Alternatives rejected.** QUIC now (immaturity risk, you'd rebuild reliability for control anyway). WebRTC (different architecture, extra jitter buffer, loses tight VideoToolbox control). Raw UDP + FEC (maximum work, unnecessary on a clean link).

**Consequences.** Wi-Fi packet loss is handled at the app layer (LTR recovery + IDR requests), not by the transport. Acceptable for v1; QUIC revisited only if Wi-Fi proves inadequate.

### D4 — HEVC low-latency + H.264 fallback + LTR recovery; no AV1
**Decision.** Default codec HEVC via `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`, negotiated per-connection. `EnableLTR` on, with a receiver-driven acknowledgment loop for loss recovery. H.264 low-latency as the negotiated fallback (mandatory if a sender is ever an Intel Mac; HEVC-LL is Apple-Silicon-only). AV1 is not implemented.

**Why.** Verified: HEVC-LL is Apple-Silicon-only and the M4 Max has it; it removes frame reordering and cuts encode latency. **M4/M4 Max have no hardware AV1 *encoder*** (decode only) and the Intel i9 has no AV1 decode, so AV1 would force software paths — dead on arrival. LTR-based recovery avoids the forced-IDR bitrate-inflation trap.

**Alternatives rejected.** AV1 for this pair (impossible in hardware). H.264 primary (leaves HEVC efficiency unused on a capable sender). Forced keyframes for recovery (`max_ref_frames=1` inflation trap).

**Consequences.** Capability negotiation is required in the handshake so an Intel sender falls back to H.264. See [02 § Handshake](02-protocol.md#handshake).

### D5 — Reliability is a first-class subsystem, not scattered handlers
**Decision.** A single explicit `Session` state machine (see [03](03-reliability.md)) driven by three independent liveness detectors (app heartbeat, TCP keepalive/`connectionDropTime`, `NWPathMonitor`), plus a receiver no-frame watchdog decoupled from capture cadence, plus an encoder-stall watchdog on the sender. All socket I/O is async (`NWConnection`), never blocking the main thread. Reconnect uses exponential backoff + jitter and re-resolves via Bonjour (not a cached IP), so it works in discovery mode, not just manual-IP mode.

**Why.** This *is* the product's differentiator and the fix for every reported bug. The current failures (cable-pull hang, freeze, no-reconnect-in-Bonjour-mode, bogus latency) all trace to the absence of exactly these pieces.

**Alternatives rejected.** Relying on TCP's own timeouts (≈2 h on macOS defaults; blocking writes hang forever). Deriving liveness from frame arrival (a static screen has none). Wall-clock cross-machine latency (clock skew makes it meaningless — replaced by single-clock RTT via PING/PONG).

**Consequences.** More upfront state-machine complexity, but it's centralized and testable, and it's the reason to use this app over Universal Control / Duet.

### D6 — Security: TLS + PIN pairing where the PIN never travels; input gated on pairing
**Decision.** TLS 1.3 over `NWConnection` with self-signed certs and public-key pinning. First connection to a peer requires a 6-digit PIN shown on the Display; the PIN feeds a PAKE (SPAKE2) or TLS-PSK key derivation and is **never sent on the wire**. Paired peers are stored in Keychain by stable device identity and reconnect without a prompt. Input injection is refused from any unpaired/unpinned peer.

**Why.** The reverse input channel means an unauthenticated LAN peer gets remote *control* of the primary Mac — a hard blocker for anything beyond a trusted home network, and a footgun even personally. Sending the PIN (or a value derived from it) is the exact Moonlight MITM CVE; a PAKE/PSK avoids it. Key pinning suits p2p with no CA.

**Alternatives rejected.** Plaintext (remote-control exposure). "Send PIN and compare" (MITM). Accounts/cloud (contradicts the praised local-only, zero-account design and adds a failure class).

**Consequences.** A pairing step on first connect. Sequenced in Phase 3, after reliability, because it's a prerequisite for exposure, not for a first working build on a trusted network. See [05](05-security-and-pairing.md).

### D7 — Menu-bar-first UI; immersive Display; a permission onboarding that actually works
**Decision.** Primary surface is a `MenuBarExtra(.window)` popover (AirPlay-style device list, connect/disconnect, status dot, quick settings, opt-in HUD). A full window appears only for onboarding, permission repair, manual IP, and detailed settings. The Display role runs immersive fullscreen with an auto-hiding control bar and **multiple exit paths** (Esc + hover bar + menu-bar item) so a freeze is never a trap. Permission onboarding is a live checklist that handles the Screen Recording request/relaunch trap and the Local Network pane that has no deep link.

**Why.** Every strong comparator is menu-bar/Control-Center-first; it makes the app feel like a system utility and keeps the sender's footprint light. The permission gauntlet (Screen Recording needs `CGRequestScreenCaptureAccess` + relaunch; Local Network has no deep link) is where these apps feel broken if handled naively.

**Alternatives rejected.** Document-style full-window app (Dock clutter, heavier). Menu-bar-only with no window (nowhere for onboarding/repair). Webview UI (per-webview bugs; tempts routing video through it).

**Consequences.** `LSUIElement = YES`. Onboarding must detect the granted-but-needs-relaunch state and drive a clean relaunch. See [06](06-ux-and-onboarding.md).

### D8 — Name: **Sidewire**
**Decision.** The product is **Sidewire**. Rename targets/bundle IDs/schemes in Phase 0. Suggested bundle identifier root: `com.sidewire` (final identifier fixed once, then never changed — TCC grants key on it; see [08](08-build-and-distribution.md)).

**Why.** Chosen by the owner. Positions directly against the gap ("a Mac-to-Mac Sidecar") and the "wire" evokes the direct-Thunderbolt path; not locked to "Mac."

**Consequences.** One stable bundle ID for the life of the product.

---

## Part D — What "done" and "works" mean

The owner asked, reasonably, *"will this actually work?"* The honest answer: the hard parts are already proven (the current app streams end-to-end today; the core APIs are verified current for 2026). The rebuild's risk is **not** "can we stream a screen" — that's solved — it's "can we make it recover cleanly and feel trustworthy." That risk is retired empirically, per phase, against the real M4 Max ↔ i9 pair, using the acceptance criteria in [07](07-roadmap-and-phases.md). Every phase ends with a concrete, physically-verifiable check (e.g. *"pull the Thunderbolt cable mid-stream; the Display shows 'reconnecting' within 1.5 s and fully restores within 3 s of replugging, with no hang and no phantom display left behind"*). Nothing is declared done on the basis of code review alone.
