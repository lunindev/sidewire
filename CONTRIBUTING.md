# Contributing to Sidewire

Thanks for looking. Sidewire is a pre-release, solo-maintained project: code-complete and
test-covered, but never run on two physical Macs, with no CI, no tag, and no notarized build.
[`TODO.md`](TODO.md) is the authoritative list of what is left and is worth reading before you pick
something up — it is deliberately honest about what is broken.

**Security issues do not go here.** See [`SECURITY.md`](SECURITY.md).

## Repository layout

```
app/       the product
  Sidewire/                  the macOS app target (SwiftUI, Universal 2, macOS 14+)
  Packages/SidewireProtocol/ pure Swift: framing, message catalog, codecs
  Packages/SidewireCore/     transport, TCP, Bonjour discovery, Session, CPace, trust store
  clients/sidewire-viewer/   Rust Cargo workspace — the Windows/Linux Display client
  protocol-vectors/          frozen conformance vectors (see below)
  docs/                      the specification, 00 → 11 — read these first
  scripts/release.sh         Developer ID build + DMG + notarization (macOS app only)
  project.yml                XcodeGen spec; the .xcodeproj is generated and gitignored
landing/   the marketing site — Astro + TypeScript, static
scripts/   release tooling shared by both (version bump + changelog + tag)
```

Two roles, one binary: **Source** (a Mac — creates a virtual display, captures, encodes, and injects
your input) and **Display** (a Mac, or a Windows/Linux PC running the Rust client — shows the stream
and forwards keyboard and mouse). The Source is always a Mac; creating a virtual display is
macOS-specific.

Start with [`app/docs/README.md`](app/docs/README.md). For anything touching the wire,
[`app/docs/02-protocol.md`](app/docs/02-protocol.md) and
[`app/docs/05-security-and-pairing.md`](app/docs/05-security-and-pairing.md) are normative.

## Building

### The macOS app

Requirements: **macOS 14+**, **Xcode 16+**, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Run from `app/`:

```bash
brew install xcodegen                 # once
cd app
xcodegen generate                     # (re)generate Sidewire.xcodeproj from project.yml

xcodebuild -project Sidewire.xcodeproj -scheme Sidewire -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd build
# → build/dd/Build/Products/Release/Sidewire.app
```

`-destination 'generic/platform=macOS'` is **required** for a Universal (x86_64 + arm64) binary.
Without it you get only the host arch, which will not run on an Intel Mac. Confirm:

```bash
lipo -archs build/dd/Build/Products/Release/Sidewire.app/Contents/MacOS/Sidewire   # → "x86_64 arm64"
```

`Sidewire.xcodeproj` is generated and gitignored — never commit it, and re-run `xcodegen generate`
after any change to `project.yml`.

### Code signing — the caveat that will bite you

The checked-in default is **ad-hoc** (`CODE_SIGN_IDENTITY: "-"`, `CODE_SIGNING_REQUIRED: "NO"` in
[`app/project.yml`](app/project.yml)). That is deliberate: it is the only way the tree builds for
everyone with no Apple account, no certificate, and no provisioning profile.

The cost is that **an ad-hoc signature changes on every build**, so macOS treats each rebuild as a
different app and **resets the Screen Recording and Accessibility (TCC) grants**. If you are
iterating on the Source role you will re-approve permissions constantly.

The fix is to sign with a stable identity of your own — and to pass it **on the command line**, not
by editing `project.yml`, so the checked-in default stays buildable for everyone:

```bash
security find-identity -v -p codesigning        # find your identity's SHA-1
xcodebuild -project Sidewire.xcodeproj -scheme Sidewire -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd build \
  CODE_SIGN_IDENTITY=<sha1> CODE_SIGNING_REQUIRED=YES
```

A PR that changes the checked-in signing identity will be rejected. Distribution signing is a
separate concern handled by `app/scripts/release.sh` (Developer ID Application + hardened runtime +
notarization) and is not something a contributor needs.

### The Rust client

Only needed when the Display is a Windows or Linux machine — but it builds and runs on macOS too,
which is the easiest way to test it against a Mac Source. Requires **Rust ≥ 1.90**, **ffmpeg 7.x**
and **pkg-config**.

```bash
brew install rust ffmpeg@7 pkg-config
```

Homebrew's `ffmpeg@7` is keg-only, so it is not on the default search paths and only the media crate
links it. Three environment variables are required on macOS:

```bash
export FFMPEG_DIR="$(brew --prefix ffmpeg@7)"
export PKG_CONFIG_PATH="$FFMPEG_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$FFMPEG_DIR/lib:$DYLD_FALLBACK_LIBRARY_PATH"

cd app/clients/sidewire-viewer
cargo build --release   # → target/release/sidewire-viewer
```

The client is **always the Display**: it listens, prints a 6-digit pairing PIN, and opens the video
window once a Mac Source connects.

```bash
cargo run --release                          # listen on :5005 + advertise over mDNS
cargo run --release -- --file some_clip.h264 # smoke-test decode → window with a local clip, no Mac
cargo run --release -- --discover            # list nearby Sidewire Displays (diagnostic only)
cargo run --release -- --handshake-only      # pair + reach CONFIG, then exit (no window)
```

A note on FFmpeg: Homebrew's `ffmpeg@7` is built `--enable-gpl --enable-version3`. Since Sidewire
is GPL-3.0-or-later this is consistent rather than a conflict, but please still do not attach built
binaries to a pull request — distributing a binary carries source-availability obligations that a PR
is the wrong place to satisfy.

### The landing site

**pnpm** (see `packageManager` in the root `package.json` for the pinned version):

```bash
cd landing
pnpm install
pnpm dev            # http://localhost:4321
pnpm build          # → dist/  (static)
pnpm check          # astro check — TypeScript / template diagnostics
```

All copy lives in one typed file, `landing/src/data/site.ts`. The components are presentational and
read from it — edit the data, not the markup, for copy changes.

## Tests

Run the suite that covers what you touched; run all of them before opening a PR.

```bash
# Swift — from app/
(cd app/Packages/SidewireProtocol && swift test)     # 40 tests
(cd app/Packages/SidewireCore     && swift test)     # 39 tests

# Rust — from app/clients/sidewire-viewer/, with the three ffmpeg env vars exported
cargo test                                           # 80 tests (+1 #[ignore]d live-mDNS round-trip)
cargo fmt --all --check
cargo clippy --workspace --all-targets
```

Some failures are pre-existing, not yours. **`TODO.md` is the live list** — check it before assuming
you broke something. The long-standing ones to know about:

- `swift test` in `SidewireCore` rewrites its own `Package.resolved` to drop a stale pin, producing a
  spurious diff on every contributor's first run. Do not commit it unless fixing that is the point of
  your PR.
- `active_source_keeps_the_link_alive` in `sidewire-viewer/tests/heartbeat.rs` has been flaky
  (a shutdown race, not a watchdog trip), and `sidewire-crypto/tests/identity.rs` shells out to
  `openssl dgst` and fails when LibreSSL precedes Homebrew's OpenSSL on `PATH`.
- If `cargo fmt --all --check` reports diffs in files you did not touch, that is tree drift — fix
  only your own files rather than turning your PR into a tree-wide reformat.

There is **no CI yet** — `.github/workflows/` does not exist. Until it does, the test output you
paste into the PR is the only evidence there is.

### `protocol-vectors/` is frozen

[`app/protocol-vectors/`](app/protocol-vectors/) is the language-neutral conformance target that lets
the Rust client be validated with no Swift toolchain. **Do not edit those JSON files casually, and
never edit them to make a failing test pass** — a diff there means the wire format changed, which is
a protocol break affecting every implementation.

They are generated from the Swift tests, not hand-written. A deliberate encoding change means:
updating [`app/docs/02-protocol.md`](app/docs/02-protocol.md) (which is normative — if a vector and
the docs disagree, that is a bug), regenerating, and saying so explicitly in the PR:

```bash
(cd app/Packages/SidewireProtocol && SIDEWIRE_WRITE_VECTORS=1 swift test)   # frame/input/message/video
(cd app/Packages/SidewireCore     && SIDEWIRE_WRITE_VECTORS=1 swift test)   # pairing
```

A plain `swift test` verifies the checked-in files still match, so accidental wire drift fails loudly.

## Commit messages — Conventional Commits (load-bearing)

This is not a style preference. [`scripts/release.mjs`](scripts/release.mjs) parses commit subjects
with the regex `^([a-zA-Z]+)(?:\(([^)]+)\))?(!)?:\s*(.+)$` and generates `CHANGELOG.md` from them. A
subject that does not match is **silently dropped from the changelog**.

```
<type>(<optional scope>): <description>
```

| Type | Changelog section |
| --- | --- |
| `feat`, `feature` | **Added** |
| `fix`, `bugfix` | **Fixed** |
| `improvement`, `improve`, `perf`, `refactor` | **Improved** |
| `chore`, `docs`, `ci`, `test`, `build`, `style`, `revert` | hidden — valid, but not in the changelog |

Anything else is dropped entirely. A `!` before the colon marks a breaking change
(`feat(protocol)!: …`). The scope is rendered in bold in the changelog, so use a real one:
`protocol`, `core`, `ui`, `viewer`, `landing`, `docs`.

Write the description so it reads well to a user in a release note — it is copied verbatim.

## Pull requests

- One logical change per PR. Keep it reviewable.
- Fill in [the template](.github/PULL_REQUEST_TEMPLATE.md); it is short on purpose.
- If your PR closes an item in [`TODO.md`](TODO.md), tick it there in the same PR. That file is the
  project's memory — a fix that leaves a stale open item is half a fix.
- Do not change the GitHub owner/repo URLs or the production domain; those are pending an owner
  decision (see *Open questions* in `TODO.md`).
- Do not commit build output: `Sidewire.xcodeproj`, `build/`, `dd/`, `target/`, `dist/`,
  `node_modules/`. And never commit signing material — the root `.gitignore` blocks the common
  extensions, but the ignore file is a backstop, not a guarantee.
- Big architectural changes: open an issue first. `app/docs/` records why things are the way they
  are, and a change that contradicts a documented decision needs the doc updated too.

## Where help is most wanted

From `TODO.md`, roughly in order of value:

1. **Testing on two physical Macs.** The single largest risk in the project and the one thing that
   cannot be closed by writing code.
2. **Live Rust↔Swift interop.** Only Rust↔Rust loopback and the golden vectors have ever run.
3. The two security items in [`SECURITY.md`](SECURITY.md) — the unauthenticated LAN DoS and the
   fail-open path in `Session`.
4. The Rust client's missing PIN overlay: the PIN is printed to stdout only, so an installed
   AppImage launched from a menu shows a window and no PIN, which makes it unusable.
5. Windows and Linux packaging — nothing in `packaging/` produces an artifact today.

## License

By contributing you agree your contributions are licensed under the
[GNU General Public License v3.0 or later](LICENSE), the same as the project.
