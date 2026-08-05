# Sidewire

**Turn a spare Mac into a real second display for your primary Mac — over a direct Thunderbolt cable or over Wi‑Fi.**

Sidewire is one universal app. Launch it on both Macs and pick a role: **Source** (shares this Mac's screen by creating a virtual display, capturing and encoding it) or **Display** (shows the other Mac's screen and forwards your keyboard & mouse). It uses `CGVirtualDisplay` + ScreenCaptureKit + hardware HEVC (VideoToolbox) and streams over TCP, secured with **certificate-based TLS 1.3 + a CPace PAKE** for pairing.

A spare **Windows or Linux** PC can be a Display too, via the native **Rust client** in
[`clients/sidewire-viewer/`](clients/sidewire-viewer/) — it speaks the identical wire protocol and pairs
with a Mac Source. (The Source is always a Mac: creating a virtual display is macOS-specific.)

> This is a ground-up rebuild of the earlier two-app *MacDisplay* prototype. The full design and phased plan live in [`docs/`](docs/README.md) — start with [docs/00-review-and-decisions.md](docs/00-review-and-decisions.md). **What is done, what is actually verified, and what is left are in [docs/11-status-and-gaps.md](docs/11-status-and-gaps.md).**

## Status

**Pre-release — code-complete and test-covered, but not yet run on physical hardware.** All phases **0–9** are implemented and committed, and the Rust Windows/Linux client is implemented (M1–M4). What is *verified*: 40 + 39 Swift tests, 80 Rust tests, and a byte-exact conformance suite ([`protocol-vectors/`](protocol-vectors/)) that both implementations reproduce independently. What is *not* verified: no build has run on two physical Macs, live Rust↔Swift interop has never been exercised, and no Windows or Linux artifact has been produced. Full detail in [docs/11-status-and-gaps.md](docs/11-status-and-gaps.md). Phases 0–5 (macOS core), in [docs/07-roadmap-and-phases.md](docs/07-roadmap-and-phases.md):

- **Phase 0** — one universal app + versioned protocol; end-to-end pipeline.
- **Phase 1** — reliability: application-level heartbeat, self-healing reconnect with backoff, no-frame & encoder-stall watchdogs, sleep/wake recovery.
- **Phase 2** — RTT-driven adaptive bitrate; latency/stats.
- **Phase 3** — encryption + 6-digit PIN pairing + input-injection gate *(migrated in Phase 7 to certificate **TLS 1.3** + a **CPace** PAKE — see below)*.
- **Phase 4** — permission onboarding (+ relaunch), immersive receiver, resolution presets.
- **Phase 5** — Developer ID signing + hardened runtime + notarized-DMG pipeline (`scripts/release.sh`; see [Distribution & notarization](#distribution--notarization)).

Additional polish landed on top: **instant local cursor** (the pointer no longer round-trips through the video), a **static-screen flicker fix** (keep-alive is gapless and the receiver's no-frame watchdog is gated on heartbeat liveness), **rotatable PIN**, **one-click Thunderbolt connect** (the Display advertises its cable IP over Bonjour), a **Settings pane** (codec / resolution / fps / bitrate), **auto-connect to the last Mac**, **menu-bar-only mode**, a **first-run welcome**, and **H.264** alongside HEVC.

The distribution build is signed + hardened but **not yet notarized** — notarization is a one-time credential step you run yourself (below).

**Next stage** (decided 2026-07-12): fix backlog → protocol v2 + TLS 1.3 → a native **Rust** Windows/Linux Display client → distribution hardening. Phases 6–9 are done: Phase 6/7 (incl. the **CPace** pairing PAKE), **Phase 8 — the native Rust Display client (M1–M4, in [`clients/sidewire-viewer/`](clients/sidewire-viewer/): pair → decode H.264/HEVC → wgpu render → HID input → heartbeat → fullscreen → mDNS)**, and **Phase 9 — Sparkle 2 auto-update + CI** (this doc's [Auto-update](#auto-update-sparkle-2) section). **Not yet done:** nothing has run on two physical Macs, live Rust↔Swift interop is unproven, and the notarization credential + Sparkle EdDSA key are one-time steps that need an Apple Developer account. **Current state is tracked in [docs/11-status-and-gaps.md](docs/11-status-and-gaps.md).** See also [docs/09-next-stage.md](docs/09-next-stage.md) (decisions + roadmap) and [docs/10-fix-backlog.md](docs/10-fix-backlog.md).

## Project layout

```
Sidewire/                     app target (SwiftUI, Universal 2, macOS 14+)
  App/                        entry, role picker/persistence, capabilities
  Roles/Source, Roles/Display controllers wiring the pipelines through a Session
  Media/                      ScreenCapture (420v), VideoEncoder (HEVC), VideoDecoder, VideoPresenter, VirtualDisplay
  Input/                      InputCapture / InputInjector (binary 32-byte events)
  UI/                         RolePicker, MenuBar, Source/Display/Settings/Welcome views
  Pairing/                    CPace PAKE over cert-TLS 1.3 (docs/05); Keychain trust store
  Settings/                   AppSettings (codec/resolution/fps/bitrate/auto-connect/menu-bar)
  Permissions/, Net/, Diagnostics/, Private/ (CGVirtualDisplay bridge)
Packages/
  SidewireProtocol/           pure Swift: framing, message catalog, codecs (unit-tested)
  SidewireCore/               Transport + TCP + Bonjour discovery + Session (unit-tested)
docs/                         the specification (read 00 → 11)
clients/sidewire-viewer/      Rust Windows/Linux Display client (Phase 8; Cargo workspace)
project.yml                   XcodeGen spec
```

## Building (console)

There are two things to build: the **macOS app** (the Source *and* the Display for two Macs) and,
optionally, the **Rust client** (a Windows/Linux Display). All commands below are copy-pasteable — no
Xcode GUI needed. Run them from the `app/` directory (this file's directory) unless noted — the
native app now lives under `app/` in the monorepo (the landing site is in `../landing/`).

### 1. The macOS app (runs on both your M4 Max and the Intel i9)

Requirements: macOS 14+, Xcode 16+ (developed on Xcode 26 / Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen                 # once, if needed
xcodegen generate                     # (re)generate Sidewire.xcodeproj from project.yml

# Build a runnable, optimized, UNIVERSAL .app from the command line. The
# `-destination 'generic/platform=macOS'` is REQUIRED for a Universal (x86_64 + arm64)
# binary — without it xcodebuild builds only the machine's active arch (arm64 on Apple silicon),
# which would NOT run on the Intel i9. Use Release (optimized encode/decode), not Debug.
xcodebuild -project Sidewire.xcodeproj -scheme Sidewire -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd build
# → the app is at:  build/dd/Build/Products/Release/Sidewire.app
open build/dd/Build/Products/Release/Sidewire.app          # launch it on THIS Mac
```

The app is a **Universal 2 binary — the *same* build runs natively on the Apple-silicon M4 Max and the
Intel i9.** Confirm both slices are present:

```bash
lipo -archs build/dd/Build/Products/Release/Sidewire.app/Contents/MacOS/Sidewire   # → "x86_64 arm64"
```

If you see only `arm64`, you omitted `-destination 'generic/platform=macOS'` — rebuild with it.

**To try it on the Intel i9:** copy `Sidewire.app` to the i9 (AirDrop / a shared folder / a USB stick)
and double-click it. An app you build locally and copy over is **not quarantined**, so Gatekeeper
doesn't block it — no notarization needed just to run it on your own two Macs. Each Mac prompts for its
own permissions on first launch (Screen Recording + Accessibility on the Source; Local Network on both).
For a signed, drag-install DMG (needed to hand it to Macs you don't control), use `./scripts/release.sh`
(also Universal; see [Distribution](#distribution--notarization)). A quick Debug build for iterating on the
Apple-silicon Mac only: drop `-destination …` and use `-configuration Debug`.

Run the package unit tests without Xcode:

```bash
(cd Packages/SidewireProtocol && swift test)     # 40 tests
(cd Packages/SidewireCore && swift test)         # 39 tests
```

The everyday build signs with a stable **Apple Development** identity (by certificate hash, no Xcode
account/provisioning needed) so **Screen Recording / Accessibility grants survive rebuilds**.

### 2. The Rust client (a Windows/Linux Display)

The i9 test above uses the macOS app on *both* Macs. The **Rust client** is only needed when the Display
is a **Windows or Linux** machine — it speaks the exact same wire protocol and pairs with a Mac Source.
You can build and run it on macOS too (to test it locally / against a Mac Source over the LAN).

```bash
# Prereqs on macOS. ffmpeg@7 is keg-only (it does not shadow a system ffmpeg 8); only the media
# crate links it. Rust ≥ 1.90.
brew install rust ffmpeg@7 pkg-config

# The media crate needs these env vars on macOS (keg-only ffmpeg@7 → not on the default paths):
export FFMPEG_DIR="$(brew --prefix ffmpeg@7)"
export PKG_CONFIG_PATH="$FFMPEG_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$FFMPEG_DIR/lib:$DYLD_FALLBACK_LIBRARY_PATH"

cd clients/sidewire-viewer
cargo test              # 80 tests (+1 #[ignore]d live-mDNS round-trip)
cargo build --release   # → target/release/sidewire-viewer
```

Run it (it is always the **Display** — it listens, prints a 6-digit pairing PIN, and opens the video
window once a Mac Source connects):

```bash
cargo run --release                          # listen on :5005 + advertise over mDNS; wait for a Source
cargo run --release -- --file some_clip.h264 # smoke test the decode→window pipeline with a local clip (no Mac)
cargo run --release -- --discover            # list nearby Sidewire Displays on the LAN
cargo run --release -- --handshake-only      # pair + reach CONFIG then exit (no window)
```

Building **for the actual Windows/Linux targets** needs that OS's Rust toolchain + a bundled/installed
ffmpeg 7.x + a Vulkan/D3D GPU driver — see [`clients/sidewire-viewer/README.md`](clients/sidewire-viewer/README.md)
and [`clients/sidewire-viewer/packaging/`](clients/sidewire-viewer/packaging/) (packaging is scaffolding,
not yet built on those OSes). ⚠️ **The Rust client has not yet been tested against a live Mac Source** —
only Rust↔Rust loopback + byte-exact protocol vectors.

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
     --apple-id "<your-apple-id-email>" --team-id "<YOUR_TEAM_ID>" \
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

Then upload `appcast.xml` + the DMG to the GitHub Release. **There is no CI yet** — `.github/workflows/` does not exist; both the build/test workflow and the signed-release workflow are still to be written (see [`TODO.md`](../TODO.md)). Every step above is manual today.

## License

[MIT](../LICENSE)
