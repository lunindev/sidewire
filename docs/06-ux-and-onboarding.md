# 06 — UX & Onboarding

Read [00 D7](00-review-and-decisions.md). Style direction: a native macOS **system utility** — menu-bar-first, SF typography, no chrome for its own sake, feels like it ships with the OS. The whole point is that it disappears into the workflow and only surfaces when it needs the user.

## Surfaces

| surface | when | contents |
|---------|------|----------|
| **Role picker** (window) | first launch, or "Switch role…" | two cards: *This Mac is the Source* / *This Mac is the Display*; "Remember on this Mac" |
| **MenuBarExtra (.window popover)** | always (both roles) | status dot, device list / connection, connect·disconnect, quick settings, HUD toggle, Quit |
| **Onboarding** (window) | until permissions granted | live permission checklist |
| **Immersive Display view** (fullscreen) | Display role, connected | the video, auto-hiding control bar |
| **Settings** (window) | on demand | resolution/fps, paired Macs, network interface, diagnostics export |

`LSUIElement = YES` (no Dock icon by default; lives in the menu bar). A window is shown explicitly for onboarding/role/settings.

## Role selection

Two large cards, plain language:
- **Source — "Share this Mac's screen."** Subtitle: "Creates an extra display here and streams it to another Mac." Pre-highlight if this Mac looks like a primary (Apple Silicon, more RAM) — but never auto-decide.
- **Display — "Use this Mac as a monitor."** Subtitle: "Shows another Mac's screen and forwards your keyboard and mouse."

Persist per-Mac; expose "Switch role…" in the menu and app menu (switching restarts the pipelines).

## Permission onboarding

This is where competitors feel broken. A live checklist, one row per permission, each with a status dot that **re-checks on window focus**, a one-line "why," and an action button.

**Source needs:** Screen Recording, Accessibility, Local Network.
**Display needs:** Local Network only.

| permission | how to request | gotcha handled |
|------------|----------------|----------------|
| **Screen Recording** | call `CGRequestScreenCaptureAccess()` (or touch `SCShareableContent`) — **not** `CGPreflight...` alone, which never registers the app so it never appears in the list | after granting, the app **must relaunch**; detect the transition and offer one "Restart to finish setup" button. Also: Sequoia re-prompts ~monthly and can silently produce black frames — detect and re-request. |
| **Accessibility** (Source, for `CGEvent` input) | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`; deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` | same relaunch requirement as Screen Recording |
| **Local Network** (macOS 15+) | add `NSLocalNetworkUsageDescription`; trigger the prompt **early** by starting the `NWListener`/`NWBrowser` during onboarding | **no deep link exists** for this pane — show a captioned screenshot/GIF of System Settings → Privacy & Security → Local Network with the app's toggle circled, plus "Open System Settings" and "Re-check". If denied, every connection silently stalls, so surface "Local Network is off — turn it on to find other Macs." |

Deep links used: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` and `...?Privacy_Accessibility`.

## Menu-bar surface (day-to-day)

`MenuBarView.swift` inside `MenuBarExtra(.menuBarExtraStyle(.window))`:
- **Status dot:** gray (idle) · blue (connecting/handshaking) · green (streaming) · amber (degraded/reconnecting) · red (failed).
- **Source:** an AirPlay-style list of discovered Displays (Bonjour), each with name, an interface badge (Wi-Fi / Thunderbolt / Ethernet) and a reachability dot; one tap connects a paired peer. A disclosure "Connect by IP…" fallback for the Thunderbolt `169.254.x.x` link-local case where Bonjour can be flaky.
- **Display:** shows listening status, the pairing PIN entry point, and the current Source when connected.
- **Quick settings:** resolution ("Match Display" + presets), fps (30/60), interface preference (Auto / prefer Thunderbolt), HUD toggle.
- **Stats HUD (opt-in):** RTT (from PING/PONG, single-clock), bitrate, resolution@fps, decoder path (HW/Metal), loss%. Compact, one line, dismissible.

## Immersive Display view

`ImmersiveDisplayView.swift`:
- Fullscreen black + the video, `resizeAspect`.
- **Auto-hiding control bar** (top): connection name, quality chip, "Exit" — appears on mouse-to-top or a brief tap, hides after a couple seconds.
- **Multiple exit paths so a freeze is never a trap:** `Esc`, the control-bar Exit button, and the menu-bar item all leave immersive mode. On entering, a brief toast: "Press Esc to exit."
- Reconnection storytelling in-view: on loss, dim the last frame and overlay the current state text — "Cable unplugged — reconnecting (2)…", "Source asleep — resuming…", "Screen Recording permission was revoked" — never a bare frozen frame, never a silent hang. Labels come straight from the [session state](03-reliability.md#session-state-machine).

## Copy principles

- Name things by what the user recognizes: "Source" / "Display", "another Mac", "keyboard and mouse" — not "sender", "peer", "input injection".
- Errors say what happened and the fix: "Local Network is off — turn it on in System Settings to find other Macs," not "NWBrowser failed."
- State is honest: "reconnecting (3)" with a visible attempt count beats a spinner that could mean anything.

## Diagnostics

An OSLog ring buffer ([01 Diagnostics](01-architecture.md)) with an "Export diagnostics…" in Settings that writes a redacted log (no screen contents, no keystrokes) for support. Useful for the private-API/permission edge cases that are otherwise invisible.
