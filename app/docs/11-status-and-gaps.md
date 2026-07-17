# 11 — Status & known gaps

*The authoritative statement of what is implemented, what is verified, and what is not. Read this
before trusting any status claim in the older design docs (00–10), which describe the plan as it was
written rather than what shipped.*

## Where the project stands

**Code-complete and test-covered, but never run on physical hardware.**

| Component | State |
| --- | --- |
| macOS app (`Sidewire/`) | Full Source/Display pipeline, protocol v2, Developer ID + hardened-runtime packaging, Sparkle 2 auto-update |
| `Packages/SidewireProtocol` | Framing, message catalog, codecs — **40 tests** |
| `Packages/SidewireCore` | Transport, TCP, Bonjour discovery, Session, CPace — **39 tests** |
| Rust client (`clients/sidewire-viewer/`) | Pairing, H.264/HEVC decode, wgpu render, HID input, heartbeat, fullscreen, mDNS advertise — **80 tests** (+1 `#[ignore]`d live-mDNS) |
| `protocol-vectors/` | Byte-exact conformance fixtures both implementations reproduce independently |

The wire protocol and pairing crypto are frozen: `protocol-vectors/`, `Packages/SidewireProtocol`,
and the CPace implementation in `Packages/SidewireCore` are the conformance target, and the Rust
client is verified against them.

## What is not verified

These are honest gaps, not TODOs waiting on a decision.

- **No build has ever run on two physical Macs.** Everything is proven by unit and integration tests,
  the byte-exact protocol vectors, and the Xcode build — not by a real session between two machines.
- **Live Rust↔Swift interop is unproven.** The Rust client has only been exercised Rust↔Rust over
  loopback TLS and against the golden vectors. One specific thing to confirm first: the Rust
  `device_id` (SHA-256 of the DER SubjectPublicKeyInfo, first 16 bytes, hex) must match what the
  Swift side computes for the same key. It is cross-checked against the OpenSSL CLI in a Rust test,
  but never against a live swift-crypto peer.
- **No Windows or Linux artifact has been produced.** `clients/sidewire-viewer/packaging/` holds a
  recipe README, a `.desktop` file and a CI sketch — scaffolding, not built or tested on those
  operating systems.
- **The app target has no automated tests.** The counts above cover the two Swift packages. The
  SwiftUI views, role controllers and the virtual-display code have no coverage.
- **Hardware decode in the Rust client is deferred.** M2 ships software decode; a `DecodeBackend`
  seam exists in `clients/sidewire-viewer/sidewire-media/src/decoder.rs` for a future
  VideoToolbox / D3D11VA / VAAPI backend.

## Trying it without any credentials

Build the Universal macOS app once and run it on both machines — one build runs natively on Apple
silicon and Intel. Full commands are in the [README § Building](../README.md#building-console).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Sidewire.xcodeproj -scheme Sidewire -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd build
lipo -archs build/dd/Build/Products/Release/Sidewire.app/Contents/MacOS/Sidewire   # expect: x86_64 arm64
open build/dd/Build/Products/Release/Sidewire.app
```

`-destination 'generic/platform=macOS'` is required for a Universal binary; without it `xcodebuild`
produces only the host architecture. Copy the `.app` to the second Mac over AirDrop, a shared folder
or a USB stick — an app copied that way is not quarantined, so it runs without notarization. Pick
**Source** on one machine and **Display** on the other, enter the Display's PIN on the Source, and
connect over Thunderbolt or Wi-Fi.

The Rust client (only needed when the Display is a Windows or Linux machine):

```bash
brew install rust ffmpeg@7 pkg-config
export FFMPEG_DIR="$(brew --prefix ffmpeg@7)"
export PKG_CONFIG_PATH="$FFMPEG_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$FFMPEG_DIR/lib:$DYLD_FALLBACK_LIBRARY_PATH"
cd clients/sidewire-viewer && cargo test && cargo build --release
cargo run --release -- --file some_clip.h264   # decode→window smoke test, no Mac needed
```

> Homebrew's `ffmpeg@7` is built `--enable-gpl --enable-version3`, i.e. GPL-3.0-or-later. It is fine
> for local development, but a redistributable binary must link an LGPL-only ffmpeg build — see
> [08-build-and-distribution.md](08-build-and-distribution.md).

## The real-hardware checklist

When two physical machines are available, exercise all of this before trusting a release:

- first-time PIN pairing, and a paired reconnect (which should skip the PIN);
- a wrong PIN (immediate, clear failure) and **Forget this Mac** → re-pair;
- cable-pull and sleep/wake recovery on both sides;
- an Intel Mac as Source, to cover the H.264 encoder-fallback path;
- both transports — Thunderbolt and Wi-Fi;
- a sustained session of an hour or more, watching for leaks and A/V desync.

## Steps that need credentials

These require an Apple Developer account and signing keys, so they cannot be completed from a clean
checkout by a contributor.

**Sparkle update-signing key** — run Sparkle's `generate_keys` once (it ships in the resolved SPM
artifact under `…/artifacts/sparkle/Sparkle/bin/`), keep the private key safe, and paste the printed
public key into `SUPublicEDKey` in [`Sidewire/Resources/Info.plist`](../Sidewire/Resources/Info.plist).
Replace `OWNER` in `SUFeedURL` with the real GitHub owner. Until a real key is set, Sparkle fails
closed and refuses every update — which is the safe default.

**Notarization** — only needed to hand the app to machines you do not control. Set
`SIDEWIRE_SIGN_IDENTITY` and `SIDEWIRE_TEAM_ID`, store notary credentials once, then run
[`scripts/release.sh`](../scripts/release.sh). See
[08-build-and-distribution.md](08-build-and-distribution.md) for the full pipeline.

**Publishing an update** — after `release.sh` produces a notarized DMG,
[`scripts/generate-appcast.sh`](../scripts/generate-appcast.sh) EdDSA-signs it into `dist/appcast.xml`.
Upload both to the GitHub Release.

## Deferred work

- Hardware decode in the Rust client (see the `DecodeBackend` seam).
- The `CGVirtualDisplay` helper subprocess is currently disabled in `VirtualDisplayManager.swift`;
  either fix the ~3 s activation-timeout regression and re-enable it, or accept in-process creation
  (open question 4 in [09-next-stage.md](09-next-stage.md)).
- Localization: the String Catalog ships English-only. Further locales are a translation task rather
  than an engineering one.
- [07-roadmap-and-phases.md](07-roadmap-and-phases.md) still describes the phases as originally
  planned; this file and [09-next-stage.md](09-next-stage.md) are authoritative for current state.
