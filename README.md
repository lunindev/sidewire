# Sidewire

**Turn a spare Mac into a real second display for your primary Mac — over a direct Thunderbolt cable or over Wi‑Fi.**

Sidewire is one universal app. Launch it on both Macs and pick a role: **Source** (shares this Mac's screen by creating a virtual display, capturing and encoding it) or **Display** (shows the other Mac's screen and forwards your keyboard & mouse). It uses `CGVirtualDisplay` + ScreenCaptureKit + hardware HEVC (VideoToolbox) and streams over TCP.

> This is a ground-up rebuild of the earlier two-app *MacDisplay* prototype. The full design and phased plan live in [`docs/`](docs/README.md) — start with [docs/00-review-and-decisions.md](docs/00-review-and-decisions.md).

## Status

**Feature-complete for personal use.** All phases 0–5 in [docs/07-roadmap-and-phases.md](docs/07-roadmap-and-phases.md) are implemented:

- **Phase 0** — one universal app + versioned protocol; end-to-end pipeline.
- **Phase 1** — reliability: application-level heartbeat, self-healing reconnect with backoff, no-frame & encoder-stall watchdogs, sleep/wake recovery.
- **Phase 2** — RTT-driven adaptive bitrate; latency/stats.
- **Phase 3** — TLS-PSK encryption + 6-digit PIN pairing + input-injection gate.
- **Phase 4** — permission onboarding (+ relaunch), immersive receiver, resolution presets.
- **Phase 5** — Developer ID signing + hardened runtime + notarized-DMG pipeline (`scripts/release.sh`; see [Distribution & notarization](#distribution--notarization)).

Additional polish landed on top: **instant local cursor** (the pointer no longer round-trips through the video), a **static-screen flicker fix** (keep-alive is gapless and the receiver's no-frame watchdog is gated on heartbeat liveness), **rotatable PIN**, **one-click Thunderbolt connect** (the Display advertises its cable IP over Bonjour), a **Settings pane** (codec / resolution / fps / bitrate), **auto-connect to the last Mac**, **menu-bar-only mode**, a **first-run welcome**, and **H.264** alongside HEVC.

The distribution build is signed + hardened but **not yet notarized** — notarization is a one-time credential step you run yourself (below).

**Next stage** (decided 2026-07-12): fix backlog → protocol v2 + TLS 1.3 → a native **Rust** Windows/Linux Display client → distribution hardening. Phases 6–9 are done: Phase 6/7 (incl. the **CPace** pairing PAKE), **Phase 8 — the native Rust Display client (M1–M4, in [`clients/sidewire-viewer/`](clients/sidewire-viewer/): pair → decode H.264/HEVC → wgpu render → HID input → heartbeat → fullscreen → mDNS)**, and **Phase 9 — Sparkle 2 auto-update + CI** (this doc's [Auto-update](#auto-update-sparkle-2) section). **Not yet done / owner-gated:** nothing has run on the real M4↔i9 hardware and live Rust↔Swift interop is unproven; the one-time notarization credential + Sparkle EdDSA key are your manual steps. **Current state is tracked in [docs/11-status-and-gaps.md](docs/11-status-and-gaps.md).** See also [docs/09-next-stage.md](docs/09-next-stage.md) (decisions + roadmap) and [docs/10-fix-backlog.md](docs/10-fix-backlog.md).

## Project layout

```
Sidewire/                     app target (SwiftUI, Universal 2, macOS 14+)
  App/                        entry, role picker/persistence, capabilities
  Roles/Source, Roles/Display controllers wiring the pipelines through a Session
  Media/                      ScreenCapture (420v), VideoEncoder (HEVC), VideoDecoder, VideoPresenter, VirtualDisplay
  Input/                      InputCapture / InputInjector (binary 32-byte events)
  UI/                         RolePicker, MenuBar, Source/Display/Settings/Welcome views
  Pairing/                    PIN → TLS-PSK key derivation (HKDF)
  Settings/                   AppSettings (codec/resolution/fps/bitrate/auto-connect/menu-bar)
  Permissions/, Net/, Diagnostics/, Private/ (CGVirtualDisplay bridge)
Packages/
  SidewireProtocol/           pure Swift: framing, message catalog, codecs (unit-tested)
  SidewireCore/               Transport + TCP + Bonjour discovery + Session (unit-tested)
docs/                         the specification (read 00 → 11)
clients/sidewire-viewer/      Rust Windows/Linux Display client (Phase 8; Cargo workspace)
project.yml                   XcodeGen spec
```

## Build

Requirements: macOS 14+, Xcode 16+ (developed on Xcode 26 / Swift 6 toolchain), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen        # if needed
xcodegen generate            # regenerate Sidewire.xcodeproj from project.yml
open Sidewire.xcodeproj       # build & run the "Sidewire" scheme
```

Run the package tests without Xcode:

```bash
(cd Packages/SidewireProtocol && swift test)
(cd Packages/SidewireCore && swift test)
```

The everyday build signs with a stable **Apple Development** identity (by certificate hash, no Xcode account/provisioning needed) so **Screen Recording / Accessibility grants survive rebuilds**. On first use the **Source** requests **Screen Recording** (to capture the virtual display) and **Accessibility** (to inject keyboard/mouse); both Macs request **Local Network**.

## Usage

1. Launch Sidewire on both Macs (a first-run welcome explains the roles).
2. On your primary Mac pick **Source**; on the spare Mac pick **Display**. The Display shows a 6-digit **pairing PIN** (rotate it with **New PIN**).
3. Enter that PIN on the Source, then connect:
   - **Thunderbolt** (recommended, lowest latency): with a cable connected, the Display advertises its cable IP and the Source shows a green **⚡ Thunderbolt** button — one click, no typing. Or use **Connect by IP** with the peer's `169.254.x.x` (the field remembers your last address).
   - **Wi-Fi**: pick the discovered Display and click **Connect**.
4. The Source creates a virtual display sized to the panel, streams it (TLS-encrypted), and forwards keyboard & mouse. Press **Esc** on the Display to leave immersive fullscreen.

**Settings (⌘,):** codec (HEVC/H.264), resolution, max frame rate, max bitrate, auto-connect to the last Mac on launch, and menu-bar-only mode.

## Distribution & notarization

The everyday build above is enough to run Sidewire on **your own Macs**. To hand the app to another Mac cleanly — double-click, no "unidentified developer" warnings, no `xattr` dance — it needs to be **notarized**. Here's the mechanism and the steps.

**How Gatekeeper works.** macOS only scrutinizes an app that carries a *quarantine* flag, which the system attaches when a file arrives from "outside" (download, AirDrop, email). An app you build locally or copy over the LAN is **not** quarantined and just runs. For a quarantined app, Gatekeeper requires it to be **notarized**: signed with a **Developer ID Application** certificate and scanned by Apple's automated notary service, which then issues a ticket you *staple* to the app. (Notarization is a malware/signature scan, **not** an API-policy review — it does not object to the private `CGVirtualDisplay` API, so signing this app is fine.) Developer ID **without** notarization does not help a quarantined app, so the two go together.

**The pipeline is scripted.** [`scripts/release.sh`](scripts/release.sh) builds a Release with **Developer ID Application** signing + **hardened runtime** + a secure timestamp (this override applies to distribution only — it never changes the dev signing above), verifies the signature, packages a drag-install **DMG** (app + `/Applications` symlink), then **notarizes and staples** both the app and the DMG. Without notary credentials it still builds + signs + makes the DMG and prints the setup command.

**One-time setup (you run this — it never exposes your password to the tooling):**

1. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com) → **Sign-In and Security → App-Specific Passwords**.
2. Store it in a notarytool keychain profile:
   ```bash
   xcrun notarytool store-credentials sidewire-notary \
     --apple-id "<your-apple-id-email>" --team-id <YOUR_TEAM_ID> \
     --password <app-specific-password>
   ```

**Then, any time you want a shippable build:**
```bash
./scripts/release.sh        # → dist/Sidewire-<version>.dmg, signed + notarized + stapled
```

> The distribution build is signed with a **different** identity (Developer ID) than the dev build (Apple Development), so on first launch it re-requests Screen Recording / Accessibility (fresh TCC grants) — expected for the distributable version. Because Mac App Store review rejects the private display API, App Store distribution is not possible; Developer ID + notarization is the correct channel (see [docs/08](docs/08-build-and-distribution.md)).

## Auto-update (Sparkle 2)

Sidewire updates itself with [Sparkle 2](https://sparkle-project.org) — an **EdDSA-signed** appcast hosted on GitHub Releases. **Check for Updates…** lives in the app menu (and the menu-bar window), and Settings has an opt-in **"Automatically check for updates"** toggle (off by default).

> **Sparkle is Sidewire's first and only "phone-home."** The app is otherwise **100 % local** — no accounts, no analytics, no telemetry, no other network calls anywhere in the code. It only reaches the internet to look for a newer signed version, and only when you ask (or opt into background checks).

**Owner one-time setup** (before the first release):

1. Generate the update key pair once with Sparkle's `generate_keys` (ships in the resolved Sparkle SPM artifact under `…/SourcePackages/artifacts/sparkle/Sparkle/bin/`). Keep the **private** key in your login keychain.
2. Paste the printed **public** key into `SUPublicEDKey` in [`Sidewire/Resources/Info.plist`](Sidewire/Resources/Info.plist), and set `SUFeedURL`'s `OWNER` to the real GitHub owner. *Until you do, Sparkle **fails closed** — it refuses any update it can't verify, which is the safe default.*

**Per release**, after `./scripts/release.sh` builds + notarizes the DMG:

```bash
./scripts/generate-appcast.sh     # EdDSA-signs dist/*.dmg → dist/appcast.xml (needs your key)
```

Then upload `appcast.xml` + the DMG to the GitHub Release. CI ([`.github/workflows/`](.github/workflows/)): `ci.yml` builds + runs both test suites on every push/PR; `release.yml` is a documented, secret-gated sketch of the full signed/notarized/appcast release.

## License

[MIT](LICENSE)
