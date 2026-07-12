# 09 — Next Stage: Decisions & Roadmap v2

*Recorded 2026-07-12 after a full review of the implemented app (code, docs, and external research on Mac App Store policy, cross-platform client stacks, and router-less Wi-Fi). Decisions below were made by the owner. This document extends [00-review-and-decisions.md](00-review-and-decisions.md) (D1–D8) and supersedes parts of the "Out of scope" list in [07-roadmap-and-phases.md](07-roadmap-and-phases.md): a Windows/Linux **Display client is now in scope**; direct/ad-hoc Wi-Fi is explicitly **out**.*

**Read together with [10-fix-backlog.md](10-fix-backlog.md)** — the concrete, file-referenced list of bugs, UX traps, missing settings, and edge cases found by the same analysis. Start there for Phase 6 work and here for Phases 7–9.

**Key freedom: the app has not shipped to anyone yet** (owner statement, 2026-07-12). There are no external users and no compatibility burden. Breaking wire-protocol changes are allowed and should be made *now*, before the first release and before any second client exists.

---

## Decisions (continuing the ADR numbering from doc 00)

### D9 — Distribution: Developer ID only; the product is never feature-cut for a store

The Mac App Store is permanently closed to the full product: `CGVirtualDisplay` is a private API (automatic Guideline 2.5.1 rejection) and `CGEventPost` input injection cannot work under the mandatory App Sandbox (confirmed by Apple DTS guidance). Every comparable product (Duet Display, Luna Display, BetterDisplay, DisplayLink) ships its Mac engine outside MAS.

**Decided:** ship full-featured via Developer ID + notarized DMG (the existing `scripts/release.sh` pipeline). **Rejected:** a feature-degraded MAS build (mirror-only, no virtual display, no input injection) — not worth building. **Possible later, not planned:** putting a *client/viewer* app (iPad, or a Mac viewer) on the App Store for discoverability, the Duet/Luna pattern — clients need no private APIs.

### D10 — Windows/Linux Display client: native, in Rust

A Windows/Linux machine will act as the **Display** role only (render the incoming stream fullscreen, send back mouse/keyboard). The Source role stays Mac-only (virtual display creation is macOS-specific).

**Decided:** one native cross-platform viewer in **Rust**. Owner explicitly wants native performance; Electron is explicitly rejected.

Stack sketch (validate during implementation):
- **Window/render:** `winit` + `wgpu` (or SDL2) — borderless fullscreen, NV12 → RGB in a trivial shader, decoded frames kept on the GPU where the decoder allows.
- **Decode:** FFmpeg with hardware acceleration (`D3D11VA`/`DXVA2` on Windows, `VAAPI` on Linux), software fallback. Candidate crates: `ffmpeg-next`, or RustDesk's `hwcodec`. Architecture to imitate (not copy — GPL): moonlight-qt's renderer-selection ladder (try hw decoders in preference order → software).
- **TLS:** the `openssl` crate. **Not rustls, not native-tls** — rustls has no external-PSK support (TLS 1.3 external PSK with `psk_dhe_ke` per D11 still requires OpenSSL on the client). Verify interop early with `openssl s_client` against the Mac listener.
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

## Roadmap v2 — phases 6–9

Same rules as doc 07: each phase independently shippable, acceptance verified physically on the real M4 Max ↔ i9 pair (plus a Windows and a Linux box from Phase 8 on).

### Phase 6 — Fix backlog (correctness, onboarding, resilience, settings)

Work through [10-fix-backlog.md](10-fix-backlog.md) in priority order (P0 → P2). Highlights: Intel-as-Source encoder bug, wrong-PIN silent loop, WelcomeView permission copy, menu-bar PIN gate, Display-side sleep/listener resilience, "Can't connect?" troubleshooting panel, missing settings (launch-at-login, keep-awake, reconnect-to-apply), String Catalog adoption.

**Acceptance:** every P0/P1 item closed with its listed verification; a fresh user on a fresh Mac can self-recover from wrong PIN, missing Local Network permission, and firewall-blocked connection using only in-app guidance; the app streams with an Intel Mac as Source (H.264).

### Phase 7 — Protocol v2 + security (prerequisite for any non-Mac client)

1. **TLS 1.3** per D11 (psk_dhe_ke; per-peer stored key after pairing; trust store; rate limiting; "wrong PIN" surfaced).
2. **Input mapping:** replace raw macOS virtual keycodes / NSEvent modifier flags on the wire with a platform-neutral encoding (USB HID usage IDs recommended), declared via a `Capabilities.inputMapping` field. This must land *before* the Rust client or macOS keycodes become a de-facto permanent contract.
3. **Timestamps:** add a PTS to the video subheader (flag-gated u64 monotonic time) so non-Mac clients can jitter-buffer; today frames are stamped on arrival (`VideoDecoder.swift:187`).
4. **Fail loud:** BYE("protocol") on JSON decode failure instead of the current silent drop (a foreign client with any field mismatch currently just hangs to the 10 s timeout); kill the silent `"h264"` codec fallback in `Session.negotiate` (`Session.swift:288`); align `Reconnector.fatalReasons` with docs/02 (add "error"); send DISPLAY_INFO only after peer validation.
5. **Evolution policy:** all future JSON fields optional-with-defaults; decoders ignore unknown fields; senders never add required fields. Write it into docs/02.
6. **Freeze docs/02 as the normative spec** and export golden byte-level test vectors from the Swift tests (FrameTests/MessageTests) into a language-neutral fixture set (e.g. JSON + hex) for the Rust client to test against.

**Acceptance:** packet capture shows TLS 1.3; a wrong PIN yields an immediate, human-readable error on the Source; `openssl s_client` interop against the Mac listener documented and green; golden vectors committed; docs/02 updated to v2 and marked normative.

### Phase 8 — Rust viewer (Windows + Linux)

Milestones:
- **M1:** `sidewire-proto` Rust crate — framing + messages + input records, validated against the Phase 7 golden vectors; TLS 1.3 PSK connect to the Mac listener via `openssl` crate.
- **M2:** headless→windowed decode: receive stream, FFmpeg hw decode, render in a resizable window; measure glass-to-glass latency vs the Mac client.
- **M3:** fullscreen immersive mode + input capture/translation (HID mapping from Phase 7) + reconnect parity (heartbeat, watchdogs per docs/03 semantics — note the implicit contract: the peer must send *something* every ≤2.5 s or the Mac side's watchdog closes the session).
- **M4:** discovery (mDNS browse + manual IP), packaging (zip/MSI, AppImage/deb), a "Connect to Sidewire" first-run screen mirroring the Mac Display role's UX.

**Acceptance:** on real Windows 11 and Ubuntu LTS hardware: discovery or manual-IP connect, PIN pairing, fullscreen extended desktop at 1440p60 with hardware decode confirmed, keyboard (incl. non-US layout basics) and mouse correct, cable-pull/sleep recovery matches the Mac client's behavior, sustained session ≥ 1 h without leak/desync.

### Phase 9 — Distribution hardening

- Run the one-time notarization credential step; ship the first notarized DMG (`scripts/release.sh`).
- Fix `release.sh` version detection (reads a literal `$(MARKETING_VERSION)` today — every DMG is named `Sidewire-1.0.dmg`; read it from `project.yml` or the built product) and add a `lipo -archs` universality assertion (backlog A5).
- Sparkle 2 auto-update (EdDSA, appcast on GitHub Releases) **before** wide distribution — a DMG in users' hands has no update path. Note: Sparkle is the app's first and only "phone-home"; the product is otherwise 100 % local (no accounts, no telemetry, no HTTP anywhere in the code) — keep it that way and say so in the docs/help.
- CI per the docs/08 sketch when worthwhile.

**Acceptance:** docs/07 Phase 5 acceptance finally met end-to-end (clean-Mac Gatekeeper pass offline, TCC survives a Sparkle update), DMG names track real versions, both arches asserted in every release.

---

## Open questions for the owner

1. **Localization scope at v1** — English-only or multi-locale (D13 default: catalog now, English copy first).
2. **Rust client UI depth** — bare viewer (fullscreen + a connect dialog) vs settings/HUD parity with the Mac Display role. Default assumption: bare viewer first.
3. **LTR loss recovery** (reverted in commit `17a117a`, `ltrToken` reserved on the wire) — re-land per docs/04, or accept IDR-based recovery permanently? Affects protocol v2 (keep or repurpose the subheader field).
4. **Helper subprocess** for `CGVirtualDisplay` (disabled: `VirtualDisplayManager.swift:33`) — fix the ~3 s activation-timeout regression and re-enable (docs/00 C2 called it required), or accept in-process creation. Backlog B14.
