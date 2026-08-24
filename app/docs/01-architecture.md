# 01 — Architecture

One universal app, one binary, role chosen at launch. Three logical layers, mapped onto concrete Xcode/SwiftPM units. Read [00](00-decisions.md) first for the decisions this realizes.

## Layers

```
┌───────────────────────────────────────────────────────────────────────┐
│  L3  UI PLANE  — native SwiftUI                                         │
│      Role picker · MenuBarExtra surface · onboarding · immersive view   │
│      · HUD · settings.   (App target only.)                             │
├───────────────────────────────────────────────────────────────────────┤
│  L2  CONTROL / WIRE PLANE  — pure Swift, no AppKit/SCK/VT               │
│      Protocol framing & messages · handshake/negotiation · Session      │
│      state machine · reconnect engine · heartbeat · transport abstract. │
│      (SwiftPM packages: SidewireProtocol, SidewireCore.)                │
├───────────────────────────────────────────────────────────────────────┤
│  L1  MEDIA PLANE  — Apple-only, inherently native                      │
│      Capture (SCK) · Encode/Decode (VideoToolbox) · Present (ASBDL) ·    │
│      Virtual display (CGVirtualDisplay, in helper) · Input (CGEvent).    │
│      (App target + one helper executable target.)                       │
└───────────────────────────────────────────────────────────────────────┘
```

The L1/L2 boundary is deliberate: L2 has zero platform-media dependencies and is unit-testable without a display or a second machine. It is the only part that would ever be reused for a non-Apple peer, so it stays clean — but per [00 C1] we do not build for that now.

## Targets & packages

```
Sidewire.xcodeproj
├── Sidewire                      (app target · macOS 14+ · Universal 2 · LSUIElement)
├── SidewireDisplayHelper         (helper executable · creates CGVirtualDisplay · Phase 1)
├── Packages/
│   ├── SidewireProtocol          (SwiftPM · pure · framing + messages + codec of messages)
│   └── SidewireCore              (SwiftPM · depends on SidewireProtocol + Network · Session,
│                                   reconnect, heartbeat, transport)
└── Tests/
    ├── SidewireProtocolTests     (round-trip encode/decode, unknown-message skipping, versioning)
    └── SidewireCoreTests         (state-machine transitions, backoff, heartbeat timeouts — fake transport)
```

Why packages and not just folders: `SidewireProtocol` and `SidewireCore` must be testable in isolation (no screen, no permissions, no second Mac). A fake in-memory `Transport` lets the whole reconnect state machine be unit-tested deterministically. The media plane can't be unit-tested that way, so it stays in the app target.

## App target directory layout

```
Sidewire/
├── App/
│   ├── SidewireApp.swift              // @main; MenuBarExtra + Window scenes; role routing
│   ├── AppModel.swift                 // top-level ObservableObject; owns the active role controller
│   ├── Role.swift                     // enum Role { case source, display }; persistence
│   └── AppConstants.swift             // bundle id, service type, version — see 02/03 constants
├── Roles/
│   ├── Source/
│   │   └── SourceController.swift      // wires VirtualDisplay→Capture→Encoder→Session; input inject
│   └── Display/
│       └── DisplayController.swift     // wires Session→Decoder→Presenter; input capture
├── Media/
│   ├── ScreenCapture.swift            // SCStream wrapper (SCK)
│   ├── VideoEncoder.swift             // VTCompressionSession (HEVC-LL / H.264, LTR)
│   ├── VideoDecoder.swift             // VTDecompressionSession (+ requiresFlush handling)
│   ├── VideoPresenter.swift           // AVSampleBufferDisplayLayer host view
│   └── VirtualDisplay/
│       ├── VirtualDisplayController.swift   // async boundary the app talks to
│       ├── VirtualDisplayClient.swift       // talks to the helper subprocess (Phase 1)
│       └── CGVirtualDisplayBridge.swift     // NSClassFromString wrappers + guardrails
├── Input/
│   ├── InputCapture.swift             // NSEvent local monitor (Display)
│   └── InputInjector.swift            // CGEvent injection (Source)
├── Pairing/
│   ├── TrustStore.swift               // Keychain-backed paired-peer store
│   └── Pairing.swift                  // PIN/PAKE handshake (Phase 3)
├── UI/
│   ├── RolePickerView.swift
│   ├── MenuBarView.swift              // the .window popover content
│   ├── OnboardingView.swift          // permission checklist
│   ├── ImmersiveDisplayView.swift    // fullscreen receiver + auto-hide control bar
│   ├── StatsHUD.swift
│   └── SettingsView.swift
├── Diagnostics/
│   ├── Log.swift                      // OSLog wrappers + ring buffer for support export
│   └── Stats.swift                    // rolling FPS/RTT/bitrate/loss
├── Permissions/
│   └── Permissions.swift              // Screen Recording / Accessibility / Local Network checks + prompts
├── Private/
│   ├── CGVirtualDisplayPrivate.h      // reverse-engineered headers (exists today)
│   └── Sidewire-Bridging-Header.h
├── Resources/
│   └── Info.plist, *.entitlements, Assets
```

`SidewireDisplayHelper` (separate executable target, Phase 1) is tiny: it links the same `CGVirtualDisplayBridge`, creates/owns the display, and speaks a minimal XPC/socket protocol to the app (create, apply-mode, destroy, health-ping). It exists because `CGVirtualDisplay` registers reliably only from a clean process (see [00 C2]).

## Process model

```
Source Mac                                   Display Mac
──────────                                   ───────────
Sidewire.app (main process)                  Sidewire.app (main process)
  ├─ SourceController                          ├─ DisplayController
  ├─ ScreenCapture (SCK)                       ├─ VideoDecoder (VT)
  ├─ VideoEncoder (VT)                         ├─ VideoPresenter (ASBDL)
  ├─ InputInjector (CGEvent)                   ├─ InputCapture (NSEvent)
  ├─ Session (SidewireCore)  ── TCP/TLS ─────► ├─ Session (SidewireCore)  (listener)
  └─ VirtualDisplayClient ──XPC──┐             └─ (no helper needed on Display)
                                 ▼
        SidewireDisplayHelper (subprocess, owns CGVirtualDisplay)
```

- The **Source** launches the helper subprocess on demand; the helper owns the `CGVirtualDisplay` and survives an encoder/transport crash in the main app. On main-app exit or crash, the helper detects the broken XPC channel and tears the display down (no phantom monitor). A PID/lock file lets a relaunched app find and clean orphaned helpers.
- The **Display** needs no helper — it only decodes and presents.
- Only one media pipeline is active per app instance; role is fixed for the session (switching role restarts the pipelines).

## Concurrency model (Swift Concurrency)

The design has several independent event sources (capture callbacks, socket reads, heartbeat timer, path monitor, UI actions) that must feed one coherent state machine without data races or main-thread blocking. Use actors, not locks:

| Unit | Isolation | Notes |
|------|-----------|-------|
| `Session` | `actor` (in `SidewireCore`) | Owns connection state, the state machine, heartbeat, reconnect. All transitions serialized here. |
| `Transport` | `actor` conforming to a `Transport` protocol | Wraps `NWConnection`; exposes `send(_:)`, an `AsyncStream<Inbound>` of framed messages, and a state stream. |
| `ScreenCapture` | delegate on a dedicated `DispatchQueue` → hands frames to an `Encoder` actor | SCK requires a sample-handler queue; keep it off main. |
| `VideoEncoder` | `actor` | Serializes `VTCompressionSessionEncodeFrame`; emits encoded frames via continuation. |
| `VideoDecoder` | `actor` | Serializes decode; emits `CMSampleBuffer`s. |
| `VideoPresenter` | `@MainActor` | `AVSampleBufferDisplayLayer` must be touched on main. |
| UI (`AppModel`, controllers' published state) | `@MainActor` | SwiftUI observation. |

Rules:
- **No blocking socket calls.** Everything is `NWConnection` async APIs surfaced as `async`/`AsyncStream`. A stalled peer can never freeze the UI.
- Media hot paths (capture→encode, decode→present) avoid actor hops where they'd add latency: capture delivers on its queue and the encoder consumes there; only the *encoded output* crosses into `Session`.
- The `Session` actor is the single writer of connection state; UI reads a `@MainActor` projection it publishes.

## Data flow (streaming, steady state)

**Source:** `CGVirtualDisplay` (helper) → macOS composites windows onto it → `ScreenCapture` (SCK, 420v `IOSurface`) → `VideoEncoder` (HEVC-LL, zero-copy) → Annex-B NALs → `Session.send(.video)` → TCP/TLS.
Reverse: `Session` inbound `.input` → `InputInjector` (`CGEvent`) → mapped onto the virtual display's bounds.

**Display:** TCP/TLS → `Session` inbound `.video` → `VideoDecoder` (VT) → `CMSampleBuffer` → `VideoPresenter` (ASBDL, DisplayImmediately).
Reverse: `InputCapture` (NSEvent, normalized coords) → `Session.send(.input)`.

Both directions share the same `Session`/`Transport`; heartbeat (PING/PONG) and control messages (IDR request, LTR ack, feedback, display info) ride the same connection. See [02](02-protocol.md).

## Where each earlier-code concept lands

| Today (MacDisplay) | Sidewire |
|---|---|
| `SenderApp` + `ReceiverApp` (2 apps) | one `Sidewire` app, `Role` enum |
| `Protocol.swift` (13-byte header) | `SidewireProtocol` package (versioned framing + message catalog) |
| `NetworkSender` / `NetworkReceiver` | `SidewireCore`: `Session` actor + `Transport` (symmetric; role picks listener vs connector) |
| `ScreenCapture`, `VideoEncoder` | `Media/` (largely portable; add 420v, LTR) |
| `VideoDecoder`, `DisplayWindow` | `Media/VideoDecoder`, `Media/VideoPresenter` (add `requiresFlush` handling) |
| `VirtualDisplay` (in-process) | `Media/VirtualDisplay/*` + `SidewireDisplayHelper` (Phase 1) |
| `InputInjector`, `InputCapture` | `Input/` (binary-packed events) |
| `SenderView` / `ReceiverView` | `UI/` (menu-bar-first + immersive) |
