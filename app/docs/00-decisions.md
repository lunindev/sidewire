# 00 — Design decisions

The architectural decisions behind Sidewire and, more importantly, *why* — so that a change which
looks obviously better in isolation can be weighed against the reason it was not taken.

Recorded as they were made. Where a later decision supersedes an earlier one, the earlier entry says
so rather than being edited away.

---

### D1 — One universal Swift app; no Rust/C++ core
**Decision.** A single Xcode project producing one non-sandboxed, hardened-runtime, Universal 2 (arm64 + x86_64) SwiftUI app targeting macOS 14+. Role (Source / Display) chosen at launch and remembered. All logic in Swift; protocol/session logic extracted into local Swift packages for testability.

**Why.** Every latency-critical capability is Apple-native and Swift-first: ScreenCaptureKit, `CGVirtualDisplay`, VideoToolbox, `CGEvent`, `AVSampleBufferDisplayLayer`, Network.framework. Swift Concurrency (actors) fits the "many independent liveness sources feeding one state machine" shape cleanly. With cross-platform dropped, there is no code to share with a non-Apple peer, so a Rust/C++ core would only add FFI friction with no payoff. **Will it scale?** Yes — the ceiling here is macOS APIs and the hardware encoder, not the language; Swift imposes no relevant limit for a two-machine LAN media pipeline.

**Alternatives rejected.** Rust/C++ shared core (no payoff without a second platform; still needs a Swift shim for the private display API). Electron/Tauri (webview decode-to-canvas latency and per-webview codec bugs — disqualifying for low-latency video). Keeping two apps (fails the unification goal, doubles maintenance).

**Consequences.** No Mac App Store (private API + input injection). Distribution is Developer ID + notarization only (the owner has the cert). See [08](07-build-and-distribution.md).

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
**Decision.** The product is **Sidewire**. Rename targets/bundle IDs/schemes in Phase 0. Suggested bundle identifier root: `com.sidewire` (final identifier fixed once, then never changed — TCC grants key on it; see [08](07-build-and-distribution.md)).

**Why.** Chosen by the owner. Positions directly against the gap ("a Mac-to-Mac Sidecar") and the "wire" evokes the direct-Thunderbolt path; not locked to "Mac."

**Consequences.** One stable bundle ID for the life of the product.

---

*The decisions below were taken after the first implementation was working, and cover distribution,
the second client and the v2 security migration.*

### D9 — Distribution: Developer ID only; the product is never feature-cut for a store

The Mac App Store is permanently closed to the full product: `CGVirtualDisplay` is a private API (automatic Guideline 2.5.1 rejection) and `CGEventPost` input injection cannot work under the mandatory App Sandbox (confirmed by Apple DTS guidance). Every comparable product (Duet Display, Luna Display, BetterDisplay, DisplayLink) ships its Mac engine outside MAS.

**Decided:** ship full-featured via Developer ID + notarized DMG (the existing `scripts/release.sh` pipeline). **Rejected:** a feature-degraded MAS build (mirror-only, no virtual display, no input injection) — not worth building. **Possible later, not planned:** putting a *client/viewer* app (iPad, or a Mac viewer) on the App Store for discoverability, the Duet/Luna pattern — clients need no private APIs.

### D10 — Windows/Linux Display client: native, in Rust

A Windows/Linux machine will act as the **Display** role only (render the incoming stream fullscreen, send back mouse/keyboard). The Source role stays Mac-only (virtual display creation is macOS-specific).

**Decided:** one native cross-platform viewer in **Rust**. Owner explicitly wants native performance; Electron is explicitly rejected.

Stack sketch (validate during implementation):
- **Window/render:** `winit` + `wgpu` (or SDL2) — borderless fullscreen, NV12 → RGB in a trivial shader, decoded frames kept on the GPU where the decoder allows.
- **Decode:** FFmpeg with hardware acceleration (`D3D11VA`/`DXVA2` on Windows, `VAAPI` on Linux), software fallback. Candidate crates: `ffmpeg-next`, or RustDesk's `hwcodec`. Architecture to imitate (not copy — GPL): moonlight-qt's renderer-selection ladder (try hw decoders in preference order → software).
- **TLS:** ~~the `openssl` crate~~ **`rustls`** (on the `ring` provider). *[Updated Phase 8 M1, 2026-07-12.]* The original openssl/PSK reasoning here is **stale**: it predated the Phase 7 security migration. v2 is **certificate-based TLS 1.3 + a CPace PAKE** ([05](05-security-and-pairing.md)), **not** TLS-PSK, so the "rustls lacks external-PSK" objection no longer applies. rustls with a custom accept-any cert verifier (that still verifies the handshake signature — proof-of-possession — while skipping only CA/chain trust, since pinning is app-layer) presenting a self-signed P-256 leaf is the clean path; it exposes the peer leaf certs needed for the SPKI channel binding. This is what M1 shipped and validated (`clients/sidewire-viewer/`, Rust↔Rust loopback over real TLS 1.3). No openssl crate; the only `openssl` used is the CLI, as an SPKI-fingerprint cross-check in a test. *(Live Rust↔Swift TLS interop still to be confirmed on real hardware — see [08-status-and-gaps.md](08-status-and-gaps.md).)*
- **Input:** in-window `winit` events only (no global hooks needed for a display client); translate to the wire input format per the D11/Phase 7 mapping spec.
- **Discovery:** mDNS via a Rust crate (e.g. `mdns-sd`) browsing `_sidewire._tcp`; the manual-IP:5005 path is the guaranteed fallback (works with zero discovery infra).
- **Packaging:** plain zip/MSI on Windows; AppImage + .deb on Linux.

**Rejected alternatives** (recorded so they aren't re-litigated): browser/WebCodecs viewer (zero-install and one codebase, but a latency ceiling, no OS-level key capture, and it would force a second WebSocket transport — owner chose native performance; may be revisited someday for iPad/ChromeOS reach); Electron (bundles Chromium for nothing); Flutter (external-texture plumbing outweighs UI benefits for a bare viewer); Qt/C++ (packaging burden + GPL contamination risk from moonlight-qt as the obvious reference); two per-OS native codebases (double maintenance).

What ports easily vs not: the video stream is already portable (clean Annex-B H.264/HEVC, parameter sets in-band at every IDR, no B-frames, joinable at any keyframe — any FFmpeg-class decoder eats it as-is); `Packages/SidewireProtocol` is Apple-free and its unit tests are ready-made golden vectors. The porting cost is concentrated in the TLS-PSK transport and the input-event semantics — which is exactly what Phase 7 fixes *before* the client is written.

### D11 — Security migration before any second client: TLS 1.3 + trust store

Current state (fine for two trusted Macs, unacceptable for a public product): TLS **1.2** pinned with plain-PSK `TLS_PSK_WITH_AES_128_GCM_SHA256` (`Packages/SidewireCore/Sources/SidewireCore/TLSPSK.swift:33-35`), key = HKDF of a 6-digit PIN → no forward secrecy, offline-brute-forceable from a passive capture in minutes, online-brute-forceable (no rate limiting, no lockout, no trust store).

**Decided (owner approved):** migrate to **TLS 1.3** before the Rust client ships. Minimum: external PSK with `psk_dhe_ke` (forward secrecy; interoperates with OpenSSL). Keep the 6-digit PIN as the *pairing bootstrap only*; after first pairing, store a strong random per-peer key (Keychain trust store on the Mac side, per docs/05's original design) and reconnect with that — plus "Forget this Mac", PIN attempt rate-limiting, and a user-visible "wrong PIN" error (see backlog A2). SPAKE2/PAKE remains the better end-state if a Swift implementation is practical; do not block on it.

Because nothing has shipped (see top of doc), do this as a clean **protocol v2** — no dual-stack compatibility code.

### D12 — Direct Wi-Fi (AirDrop-style, router-less): dropped

Research verdict: Mac↔Mac over AWDL (`includePeerToPeer`) is feasible but best-effort only — AWDL duty-cycling causes ~50–100 ms periodic stalls and the OS "realtime mode" that fixes it has **no public API** (Apple DTS confirmed). Wi-Fi Aware exists only on iOS/iPadOS 26, not macOS. AWDL interop from Windows/Linux is a dead end (OWL is unshippable).

**Decided:** not pursuing it. Supported transports are the existing ones: **infrastructure LAN (Ethernet / Wi-Fi) and the Thunderbolt/USB-C bridge**. The current code already matches this (`TCPTransport.swift:56` deliberately refuses `includePeerToPeer` on outbound connections). If a user has no router, the documented recipe is macOS Internet Sharing (Mac-hosted hotspot) — infrastructure mode, existing stack works unchanged; worth a help-page mention, no code.

### D13 — Localization: String Catalog scaffolding now, English-only copy first

Whether v1 ships more than one locale is undecided. **Default chosen:** adopt an `.xcstrings` String Catalog *now* while the copy volume is small (and convert the interpolated status strings that can't be extracted — see backlog F), ship v1 with English copy only, and add further locales later if desired — the catalog makes that a translation task, not an engineering task. *(OPEN question: ship additional locales at v1 or later.)*

### D14 — Architecture: no restructuring

Verdict from the code analysis: the layering is sound and multi-platform-ready — `SidewireProtocol` (pure Swift, Apple-free) / `SidewireCore` (Apple-coupled but commodity semantics: TCP + TLS-PSK + mDNS) / app media & UI. All planned work is **additive** (protocol v2, security, Rust client, backlog fixes). Do not rewrite the core.

---

