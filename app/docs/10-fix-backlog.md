# 10 — Fix Backlog

*Produced 2026-07-12 by a full code review (all file:line references verified against the working tree at the time of writing). This is the Phase 6 work list referenced by [09-next-stage.md](09-next-stage.md). Items are grouped by area and tagged **P0** (broken/misleading — fix before anything else), **P1** (real-world failure modes users will hit), **P2** (debt/polish). Each item is self-contained so it can be picked up independently.*

Security items that are part of the protocol-v2 migration live in doc 09 §D11/Phase 7, not here (except where a small local fix is possible now, e.g. A2's error surfacing).

---

## A — Correctness bugs

**A1 (P0) Intel Mac as Source is likely broken.** [Sidewire/Media/VideoEncoder.swift:32](../Sidewire/Media/VideoEncoder.swift) unconditionally passes `kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true` in the encoder spec for *both* codecs. Low-latency rate control is Apple-Silicon-only; on Intel, `VTCompressionSessionCreate` finds no matching encoder (even for H.264), the session stays nil, `encode()` no-ops, and the encoder-stall watchdog loops recreate→reconnect forever. Compounding it, `Sidewire/App/AppConstants.swift` hardcodes advertised codecs as `["hevc","h264"]` (HEVC preferred) instead of probing. **Fix:** make the low-latency spec conditional (retry session creation without it on failure, or gate on arch), and derive advertised `videoCodecs` from a real VideoToolbox capability probe. **Verify:** stream with the i9 as Source (H.264) to the M4 as Display.

**A2 (P0) Wrong PIN is indistinguishable from a network failure.** A wrong PIN fails the TLS-PSK handshake → Session hits its 10 s connect timeout with non-fatal reason "timeout" → Reconnector re-dials forever. The user sees "Connecting… / Reconnecting (n)…" with zero indication the PIN is wrong. Three entry paths: a typo; the Display rotating its PIN while the Source has the old one persisted (`sidewire.enteredPIN`); and A4 below. **Fix:** detect a TLS handshake failure distinctly in `TCPTransport`/`Session`, close with a fatal (or user-prompting) reason, show "PIN incorrect — check the code on the other Mac" in SourceView; filter the PIN field to digits-only. **Verify:** connect with a wrong PIN → immediate clear error, no reconnect loop.

**A3 (P0) Welcome screen tells users to grant Accessibility on the wrong Mac.** [Sidewire/UI/WelcomeView.swift:28](../Sidewire/UI/WelcomeView.swift) says "the display Mac needs Accessibility to forward input". Wrong: Accessibility is needed on the **Source** (it injects CGEvents; `Sidewire/Input/InputInjector.swift`, `Sidewire/Permissions/Permissions.swift`). The Display's `InputCapture` uses local NSEvent monitors needing no permission. One-line copy fix.

**A4 (P0) Menu-bar Connect bypasses the PIN gate.** The Connect button in [Sidewire/UI/MenuBarView.swift:56-57](../Sidewire/UI/MenuBarView.swift) is not gated on `pairingPIN.count == 6` (the main window is). Connecting with an empty PIN derives a PSK from an empty string and enters the A2 silent loop. **Fix:** same gating as SourceView (and after A2, the failure at least becomes visible).

**A5 (P1) release.sh version detection is dead code + no universality check.** [scripts/release.sh:30-31](../scripts/release.sh) reads `CFBundleShortVersionString` from the *source* Info.plist, which contains the literal `$(MARKETING_VERSION)`, so the guard always fires and every DMG is `Sidewire-1.0.dmg`. Also missing: the `lipo -archs` assertion (expect `x86_64 arm64`) that docs/08 calls for — a broken slice would ship silently. **Fix:** read `MARKETING_VERSION` from `project.yml` or the built product's processed Info.plist; add the lipo check.

**A6 (P1) Silent wrong-codec fallback in negotiation.** [Packages/SidewireCore/Sources/SidewireCore/Session.swift:288](../Packages/SidewireCore/Sources/SidewireCore/Session.swift): if the peers share no codec, negotiate silently picks `"h264"` anyway instead of failing with BYE("protocol"). Today it's unreachable (both sides hardcode both codecs) but it becomes live the moment A1's capability probe or a foreign client exists. Part of Phase 7 fail-loud work; cheap to fix now.

**A7 (P1) Letterboxed input is offset.** When the negotiated video aspect ratio differs from the Display panel's, the video letterboxes — but [Sidewire/Input/InputCapture.swift](../Sidewire/Input/InputCapture.swift) normalizes coordinates over the *full window content view* while `InputInjector` maps 0..1 onto the *full virtual-display bounds*, so clicks near the bars land visibly off-target. **Fix:** map input coordinates to the rendered video rect (the presenter knows it), not the content view. **Verify:** pick a 16:10 preset on a 16:9 panel; clicks land exactly.

**A8 (P1) Non-Retina receivers get a wrong-sized desktop.** The virtual display is *always* created HiDPI ([Sidewire/Media/VirtualDisplay/VirtualDisplayController.swift:49-52](../Sidewire/Media/VirtualDisplay/VirtualDisplayController.swift): `hiDPI = 1`, mode `width/2 × height/2`), and `Session.negotiate` ignores the `scaleFactor` the Display transmits in DISPLAY_INFO (it's only logged in `SourceController`). A 1x Display Mac with "Match Display" gets half the logical size (remote UI comically large). **Fix:** honor `scaleFactor` in negotiation and support a 1x virtual-display mode / preset.

---

## B — Resilience gaps

**B1 (P1) The Display role doesn't survive sleep or listener death.** No `NSWorkspace.didWakeNotification` observer on the Display side; `TCPListener` has no auto-restart (deferred per the comment at [Packages/SidewireCore/Sources/SidewireCore/TCPListener.swift:8-9](../Packages/SidewireCore/Sources/SidewireCore/TCPListener.swift)); the waiting overlay can sit at "Not listening" *while still showing a PIN*, with no Retry affordance. The Thunderbolt `tb` TXT record is captured once at listener start and never refreshed after wake/cable-plug (only a PIN rotation re-arms it). **Fix:** wake observer re-arms the listener; auto-restart on `.failed`; refresh the TXT record on interface change; Retry button on the overlay.

**B2 (P1) Accessibility revoked mid-session goes undetected.** If the Source's Accessibility grant is revoked while streaming, CGEvent posts silently stop working — the Display user's keyboard/mouse just dies with no message (the permission poll only runs while SourceView is visible). **Fix:** poll `AXIsProcessTrusted()` while streaming; surface a status message on both ends.

**B3 (P1) Two Sources fight over one Display forever.** `DisplayController.accept` is newest-wins ([Sidewire/Roles/Display/DisplayController.swift:115](../Sidewire/Roles/Display/DisplayController.swift): `close(reason: "superseded")`), and the ousted Source's Reconnector re-dials → permanent steal loop. The ousted side shows the raw string "Closed: superseded". **Fix:** treat "superseded" as fatal-for-reconnect (don't auto-redial), and/or let the Display show/reject the incoming taker.

**B4 (P2) Reconnect never gives up.** Backoff caps at 5 s and retries forever with "Reconnecting (n)…"; combined with `autoConnectLastPeer` and a stale last host, every launch re-enters an infinite loop. **Fix:** after ~N attempts show "Still trying — is Sidewire running on the other Mac?" with Cancel; consider pausing auto-connect after repeated failures.

**B5 (P2) Menu-bar-only mode can stream into a windowless void.** With the main window closed, `DisplayController` still accepts sessions; `enterImmersive` logs "presenter has no window yet" and gives up ([DisplayController.swift:340](../Sidewire/Roles/Display/DisplayController.swift)) — video decodes invisibly, input capture is armed. Also the Display's menu-bar popover never shows the pairing PIN (user must reopen the main window to read it), and the status-item icon is static (no connected/streaming state). **Fix:** open/focus the window on accept (or refuse and notify); PIN + connection state in the popover; stateful icon.

**B6 (P2) Virtual-display helper subprocess disabled.** `preferHelper = false` ([Sidewire/Media/VirtualDisplay/VirtualDisplayManager.swift:33](../Sidewire/Media/VirtualDisplay/VirtualDisplayManager.swift)) due to a ~3 s activation-timeout regression, so `CGVirtualDisplay` is created in-process — a WindowServer assertion takes down the whole app, which docs/00 C2 explicitly warned against ("required, not just defense-in-depth"). **Fix:** debug the activation timeout in the `--vd-helper` re-exec path and re-enable by default. (Owner decision pending — doc 09 open question 4.)

**B7 (P2) Multi-monitor Display Macs are half-handled.** `currentDisplayInfo()` uses `NSScreen.main` only with `refreshRate` hardcoded 60 ([DisplayController.swift:358](../Sidewire/Roles/Display/DisplayController.swift)); DISPLAY_INFO is snapshotted at accept time, so moving the window to another monitor mid-setup mismatches. **Fix:** use the window's actual screen, re-send DISPLAY_INFO on screen change (needs the Phase 7 "optional fields" policy if new fields are added).

**B8 (P2) Dangling interface selection.** The persisted `selectedInterfaceName` is never validated — if the interface no longer exists, behavior silently falls back to Auto without telling the user; `localThunderboltIP` only refreshes on discovery refresh — plugging a cable mid-session shows no hint until manual Refresh. **Fix:** validate persisted selection on load; observe interface changes (`InterfaceMonitor` exists) to refresh the Thunderbolt hint live.

---

## C — Onboarding & help (missing guidance)

**C1 (P1) No troubleshooting surface for the two most common real failures.** (a) Local Network (TCC) denied → Bonjour discovery returns nothing → eternal "Searching…" (`Sidewire/Permissions/Permissions.swift` explicitly defers Local Network handling); (b) macOS Application Firewall blocking the Display's listener → connects fail silently. Neither is mentioned anywhere in the UI. **Fix:** a "Can't connect?" disclosure in SourceView (and the Display waiting overlay) covering: Local Network permission on both Macs, the firewall, same-network/VPN interference, and both-Macs-same-role. Detect what's checkable (e.g. `NWBrowser` in `.waiting` state, denied TCC where API allows).

**C2 (P1) Raw internal strings shown to users.** "Failed: role", "Closed: superseded", "Closed: capture-stall", "listener error: …" surface verbatim. **Fix:** map close reasons to human sentences ("The other Mac is also set to Share — switch one to *Use as a display*", "Another Mac took over this display", …). Prerequisite for F1 localization.

**C3 (P2) Undocumented input limitations.** Cmd-key combos and Esc are deliberately never forwarded to the remote Mac ([Sidewire/Input/InputCapture.swift:23-24](../Sidewire/Input/InputCapture.swift)) — by design (the local user keeps control) but explained nowhere except the Esc toast. Nuance found in review: the filter only covers `.keyDown` — the matching `.keyUp`s (and Cmd `.flagsChanged`) still cross the wire, so the remote Mac can see unbalanced key events; worth fixing symmetrically when touching this. Non-US layouts/IME are unsupported (only keycodes cross the wire; the *Source's* layout interprets them). **Fix:** a short "Keyboard & mouse" help note; layout/IME support itself is Phase 7+ (HID mapping) territory.

**C4 (P2) No "which Mac should be Source" guidance.** Role cards describe mechanics only. One sentence each ("Source = the Mac whose apps you'll use; Display = the spare screen") prevents first-run confusion.

---

## D — Missing settings

All in [Sidewire/Settings/AppSettings.swift](../Sidewire/Settings/AppSettings.swift) / `SettingsView.swift` unless noted. Priority order:

- **D1 (P1) Launch at login** (`SMAppService`).
- **D2 (P1) Keep the Display Mac awake while connected** — nothing prevents its screen sleep from interrupting a session (`IOPMAssertionCreate` / `ProcessInfo` activity while streaming).
- **D3 (P1) "Reconnect to apply"** — quality settings currently apply silently on the *next* connection only; add an explicit apply/reconnect action.
- **D4 (P2) Device display name override** (currently `Host.current().localizedName`).
- **D5 (P2) 1x (non-Retina) virtual-display preset** — pairs with A8.
- **D6 (P2) Diagnostics export + verbose logging toggle** — `Diagnostics/Log.swift` promises a ring buffer + export that never landed.
- **D7 (P2) Display-side PIN management** — rotate lives only on the waiting overlay; consider "new PIN per session" option. (Trust store per doc 09 D11 will reshape this.)
- **D8 (P2) Re-show Welcome** (help-menu item).

---

## E — Media/protocol debt (context for Phase 7–8; see doc 09)

- **E1 — RESOLVED (Phase 7b).** The VIDEO subheader now carries a `u64` PTS (nanoseconds, source's monotonic capture clock): threaded from the CMSampleBuffer through `VideoEncoder.onEncodedFrame` → `Session.sendVideo(ptsNanos:)` → `VideoPayload` (12-byte subheader: `ltrToken:u16 | flags:u16 | pts:u64`). The Display parses and exposes it (`DisplayController.lastFramePTSNanos`) but still renders on arrival (no jitter buffer yet — deliberately). Byte-exact in docs/02 and `protocol-vectors/video-vectors.json`.
- **E2 — RESOLVED (Phase 7b).** Decision: **keep** `ltrToken` + the two LTR flag bits (and `LTR_ACK` 0x41) in the wire format but document LTR as *reserved for future loss recovery; senders always send 0*. This keeps the wire stable for a later loss-recovery path without carrying dead adaptive-bitrate code. Recovery stays IDR-based. Documented in docs/02 § VIDEO.
- **E3 — RESOLVED (Phase 7b).** Decision: **delete** `FEEDBACK` (0x42). It was never sent (adaptive bitrate is RTT-driven and works). The `Feedback` struct and `.feedback` case are removed from `SidewireProtocol`; `0x42` is marked *reserved (was FEEDBACK)* in docs/02 and remains skippable like any unknown type.
- **E4** H.264 uses `kVTProfileLevel_H264_High_AutoLevel`; fine for FFmpeg-class decoders, but if decoder compatibility issues surface on old hardware, Main profile is the safer floor. Note only — no action unless Phase 8 testing hits it.
- **E5 — RESOLVED (Phase 7a + 7b).** Phase 7a aligned the fatal set with docs/02. Phase 7b **flipped the default**: unknown reasons are now fatal-for-reconnect. `Reconnector` is gated by an explicit *transient* allowlist (`SessionConstants.transientReasons` = `{timeout, transport, wake, capture-stall, encoder-stall, no-video, no-frame}`, plus a nil reason); everything else — the fatal handshake/security reasons and any unknown token — does not reconnect. Real network failures are canonicalized to the transient `"transport"` reason in `TCPTransport` so a blip still reconnects. Normative reason registry in docs/02 § BYE.
- **E6 — RESOLVED (Phase 7b).** The Display now sends DISPLAY_INFO only after receiving+validating the Source's HELLO (right after its own HELLO_ACK), in `Session.receiveHello`, matching docs/02. A rejected peer no longer learns the panel description. Also fail-loud: a malformed HELLO/DISPLAY_INFO/CONFIG JSON now triggers `BYE("protocol")` instead of a silent drop → 10 s timeout.
- **E7 — RESOLVED (Phase 7a).** `TLSPSK.swift` and the `TLS_PSK_WITH_AES_128_GCM_SHA256` force-unwrap are deleted. The transport is now cert-based **TLS 1.3** with a device `SecIdentity` (`SidewireCore/TLS.swift`, `LocalIdentity.swift`); see [05](05-security-and-pairing.md).
- **E8 — RESOLVED (Phase 7a).** Encryption is non-optional: `TCPTransport`/`TCPListener` require a `LocalIdentity` and always run TLS 1.3. There is no PSK-nil plaintext path; loopback/reliability tests now spin up real TLS with throwaway identities.

---

## F — Localization (per doc 09 D13)

- **F1 (P2)** Adopt an `.xcstrings` String Catalog; convert interpolated/concatenated status strings (e.g. `SourceView` status line, "Closed: \(reason)") into format-style localizable strings — do this together with C2. English-only copy at v1; further locales later if desired.

---

## G — Build/dev-loop parity

- **G1 (P2)** Hardened runtime is applied only in `scripts/release.sh` (not in `project.yml`/Xcode configs), so hardened-runtime-only failures — especially around the `--vd-helper` self-re-exec — would surface first in a shipped build. Add a hardened local config or a periodic hardened build check.
- **G2 — RESOLVED (Phase 7a).** Code now pins TLS 1.3 (min = max), matching docs/05. `A2`/`A4` wrong-PIN surfacing also carries over: a wrong PIN is now a `BYE("auth")` from the pairing proof (still fatal-for-reconnect, still "PIN incorrect" in the UI).
