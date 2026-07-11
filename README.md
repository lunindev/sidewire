# Sidewire

**Turn a spare Mac into a real second display for your primary Mac — over a direct Thunderbolt cable or over Wi‑Fi.**

Sidewire is one universal app. Launch it on both Macs and pick a role: **Source** (shares this Mac's screen by creating a virtual display, capturing and encoding it) or **Display** (shows the other Mac's screen and forwards your keyboard & mouse). It uses `CGVirtualDisplay` + ScreenCaptureKit + hardware HEVC (VideoToolbox) and streams over TCP.

> This is a ground-up rebuild of the earlier two-app *MacDisplay* prototype. The full design and phased plan live in [`docs/`](docs/README.md) — start with [docs/00-review-and-decisions.md](docs/00-review-and-decisions.md).

## Status

**Phase 0 complete** — unified into one universal app + a versioned protocol; end-to-end pipeline ported. Reliability (kill the cable-pull hang / freezes), performance, security/pairing, UX polish, and signed distribution are Phases 1–5 in [docs/07-roadmap-and-phases.md](docs/07-roadmap-and-phases.md).

## Project layout

```
Sidewire/                     app target (SwiftUI, Universal 2, macOS 14+)
  App/                        entry, role picker/persistence, capabilities
  Roles/Source, Roles/Display controllers wiring the pipelines through a Session
  Media/                      ScreenCapture (420v), VideoEncoder (HEVC), VideoDecoder, VideoPresenter, VirtualDisplay
  Input/                      InputCapture / InputInjector (binary 32-byte events)
  UI/                         RolePicker, MenuBar, Source/Display views
  Permissions/, Diagnostics/, Private/ (CGVirtualDisplay bridge)
Packages/
  SidewireProtocol/           pure Swift: framing, message catalog, codecs (unit-tested)
  SidewireCore/               Transport + TCP + Bonjour discovery + Session (unit-tested)
docs/                         the specification (read 00 → 08)
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

Phase 0 builds unsigned for local development. On first use the **Source** requests **Screen Recording** (to capture the virtual display) and **Accessibility** (to inject keyboard/mouse); both Macs request **Local Network**. Developer‑ID signing + notarization come in Phase 5.

## Usage

1. Launch Sidewire on both Macs.
2. On your primary Mac pick **Source**; on the spare Mac pick **Display**.
3. The Source auto-discovers the Display (Bonjour) — click **Connect**. It creates a virtual display sized to the Display's panel, streams it, and forwards input. For a direct Thunderbolt link, use **Connect by IP** with the peer's `169.254.x.x` address if discovery is unavailable.

## License

[MIT](LICENSE)
