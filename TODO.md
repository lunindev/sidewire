# TODO — from here to a public release

The honest, prioritised list of what stands between Sidewire's current state and a repository people
can clone, a binary people can run, and a product page people can trust.

Items are grouped by **what they block**, not by how hard they are. Everything carries a file
reference so it can be picked up without context. Unverified claims are marked as such — do not
treat them as facts until someone checks.

**Legend:** `[ ]` open · `[x]` done · 🔒 needs credentials, hardware, or a decision only the owner
can make.

---

## P0 — Blocks making the repository public

These are things an outside reader hits in the first sixty seconds.

- [x] **Purge non-English text, personal data and AI-session notes from the whole history.**
      Done via two `git filter-repo` passes. All 53 commits preserved with byte-identical author and
      committer dates, names and messages. Verified across all 545 text blobs: no Cyrillic (all
      Unicode ranges), no personal Apple ID, no legal name, no Team ID, no local filesystem paths,
      no references to the original working language, no AI-workflow wording.

- [x] **Make the checked-in build work for anyone.**
      `app/project.yml` pinned `CODE_SIGN_IDENTITY` to a certificate SHA-1 that exists in exactly one
      keychain, so the documented build command failed on every other machine — including a fresh
      clone on the author's own. Now ad-hoc (`CODE_SIGN_IDENTITY: "-"`,
      `CODE_SIGNING_REQUIRED: "NO"`). Verified: clean `xcodegen generate` + Release build succeeds
      and produces a universal `x86_64 arm64` binary with the hardened runtime intact.

- [x] **Stop claiming CI exists.** Six files asserted `.github/workflows/` was real and runnable.
      All downgraded to "planned" and pointed here.

- [x] **Write `.github/workflows/ci.yml`.**
      The design is already spelled out in [`app/docs/08-build-and-distribution.md`](app/docs/08-build-and-distribution.md)
      — this is transcription, not design. `macos-14`; `brew install xcodegen`; `swift test` in both
      `app/Packages/*`; `xcodegen generate`; `xcodebuild` with signing disabled; `cargo test`,
      `cargo fmt --check` and `cargo clippy` for the Rust workspace. Cache SPM and Cargo.
      **Fix the three red gates below first, or the first run is red.**
      **Done.** Four jobs: the Swift packages + a universal unsigned app build with a `lipo` assertion; the Rust workspace with fmt/clippy/test plus a gate asserting the ffmpeg link set stays at three libraries; the landing build; and a hygiene job. *Never executed on a real runner* — the Xcode selection and Homebrew steps may need adjusting on the first push.

- [x] **`cargo fmt --all` — the tree is not formatted.**
      `cargo fmt --all --check` exits 1 with 7 diffs across 5 files (`sidewire-viewer/src/main.rs`,
      `src/renderer.rs`, `src/session.rs`, `tests/heartbeat.rs`, `tests/input_send.rs`). One command
      fixes it. `cargo clippy --workspace --all-targets` is already clean.
      **Done.** `cargo fmt --all --check` is clean.

- [x] **Fix the flaky heartbeat test.**
      [`sidewire-viewer/tests/heartbeat.rs:185`](app/clients/sidewire-viewer/sidewire-viewer/tests/heartbeat.rs)
      `active_source_keeps_the_link_alive` fails 10–35% of runs depending on concurrent load
      (measured: 2/20 in isolation, 7/20 with the full binary). The failure is *not* a watchdog trip
      — it is a race where the Source drops its socket before the Display reads the queued `BYE`, so
      the close reason arrives as `transport` instead of `user`. Make the Source's shutdown
      deterministic: send `BYE`, flush, then block on a read until EOF before dropping the socket.
      **Done, and it was not a test bug.** Dropping a socket with unread bytes in its receive queue makes the kernel emit an RST, and an RST lets the peer discard data it had already received — including the `BYE` written microseconds earlier. Fixed in the transport (`Wire::shutdown_gracefully`: flush → TLS `close_notify` → half-close → drain), wired into `Session::finish_close`, so it also fixes the real product path where the Mac saw `transport` instead of the reason actually sent. Verified 50/50 runs green, previously 10–35% failure.

- [x] **Fix the brittle OpenSSL cross-check test.**
      [`sidewire-crypto/tests/identity.rs:104`](app/clients/sidewire-viewer/sidewire-crypto/tests/identity.rs)
      does `rsplit_once('=')` on `openssl dgst` output. LibreSSL prints a bare digest with no
      `(stdin)= ` prefix, so the parse yields `""` and the assertion fails. It currently fails on
      this machine because `/usr/bin/openssl` (LibreSSL) precedes Homebrew's in `PATH`. *Unverified:*
      whether GitHub's `macos-14` runner puts Homebrew OpenSSL first — do not assume it passes there.
      Better fix: drop the subprocess entirely and compare the 91-byte SPKI DER against a checked-in
      golden vector.
      **Done.** Parses the last whitespace-separated token and validates it is 64 hex characters, skipping honestly if not. Verified passing — and *actually performing the cross-check*, not skipping — under both LibreSSL 3.3.6 and OpenSSL 3.6.3.

- [x] **Add `SECURITY.md`.**
      This project hand-rolls Field25519 and Elligator2 and implements a PAKE. Published without a
      disclosure channel, the first researcher who finds something files a public issue. Include: a
      contact address, "no released version yet — report against `main`", explicit scope (pairing /
      CPace, TLS channel binding, trust store, input-injection gating, the private `CGVirtualDisplay`
      bridge) and out-of-scope (landing site, unbuilt packaging), and a pointer to
      [`app/docs/05-security-and-pairing.md`](app/docs/05-security-and-pairing.md) as the threat
      model. Enable GitHub Private Vulnerability Reporting on the repo.
      **Done.** Contact address is left as a marked placeholder for the owner to fill in.

- [x] **Add `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/`, `PULL_REQUEST_TEMPLATE.md`, `CODEOWNERS`.**
      None exist. `CONTRIBUTING.md` matters most: it is where "you need Xcode 16+, XcodeGen, and
      ffmpeg 7 for the Rust client" belongs, plus the ad-hoc-signing TCC caveat.
      **Mostly done.** `CONTRIBUTING.md`, the two issue forms, `config.yml` and the PR template exist. `CODEOWNERS` is deliberately not created — it needs a GitHub username that has not been chosen.

- [x] **Harden `.gitignore` against signing material.**
      Add `*.p12`, `*.pem`, `*.cer`, `*.mobileprovision`, `AuthKey_*.p8`, `*_ed_key`, and a generic
      `target/`. The Rust `target/` is already covered by
      `app/clients/sidewire-viewer/.gitignore`, but a root-level rule is cheap insurance.
      **Done.**

- [ ] **Add a screenshot or a short GIF to the README.**
      There is not one image or badge in any README. For a product whose entire pitch is *"a real
      second desktop"*, showing it is worth more than several paragraphs.

- [x] **Decide what happens to `.gitlab-ci.yml`.**
      It is inert on GitHub. Either port the landing build to GitHub Actions and delete it, or keep
      it and say in one line that it serves a GitLab mirror.
      **Done — deleted.** It could never have worked on GitHub, and could not have worked on GitLab either: it was gated on tags the release tooling failed to push, and pinned to a self-hosted runner (`tags: - local`) that does not exist on shared infrastructure. Replaced by `.github/workflows/release-landing.yml`, which builds the same `landing-prod` target and pushes to GHCR on a tag. The container was kept rather than moving to Pages because the site's strict CSP and `Permissions-Policy` come from `nginx.conf`, and Pages cannot set response headers. All references repointed.

---

## P1 — Blocks the first release

### Release plumbing

- [x] **Annotated release tag.** `scripts/release.mjs` created a *lightweight* tag while the
      documented push is `git push --follow-tags`, which only pushes annotated tags — so the tag
      never reached any remote and no tag-triggered pipeline could ever fire. This is why the repo
      has 53 commits and zero tags, and why the GitLab landing build has never run.

- [x] **`release-undo.mjs` could hard-reset published history.** It only checked whether the *tag*
      was on origin, never the commit. Now it fetches and refuses if the release commit is reachable
      from any `origin/*`, suggesting `git revert` instead.

- [x] **Add a strict mode to `app/scripts/release.sh`.**
      [Line 152](app/scripts/release.sh): when the notarytool keychain profile is missing, the script
      builds an **unnotarized** DMG and `exit 0`s — and that `exit 0` sits *above* the Sparkle block,
      so the run also produces no `appcast.xml`. In CI that is a green job publishing an unsigned-in-
      practice artifact. Add `SIDEWIRE_STRICT=1` that turns the missing-credentials branch into a
      hard failure, and accept `--key/--key-id/--issuer` so no keychain profile is needed at all.
      **Done.** `SIDEWIRE_STRICT=1` turns missing credentials into a hard failure, and the script now accepts an App Store Connect API key via `NOTARY_KEY_PATH`/`NOTARY_KEY_ID`/`NOTARY_ISSUER_ID`, so CI needs no keychain profile.

- [x] **Reorder `release.sh`: it deletes before it validates.**
      `rm -rf "$OUT" "$DD"` runs *before* the Sparkle preflight, so a guaranteed-to-fail run still
      wipes any previously built DMG, `appcast.xml`, and the resolved SPM artifacts that
      `generate-appcast.sh` depends on. Move the preflight above the cleanup.
      **Done.** Verified: a run on an unconfigured tree now fails without creating or destroying `dist/`.

- [x] **Teach `generate-appcast.sh` to read the key from an environment variable.**
      [Line 80](app/scripts/generate-appcast.sh) passes no key flag, so it only works against a login
      keychain. Sparkle 2.9.4's `generate_appcast` supports `--ed-key-file -`, reading the key from
      stdin (confirmed by reading Sparkle's own source — this is *not* the deprecated `-s` flag most
      guides suggest). The secret must be a single line with no trailing newline.
      **Done.** Uses `--ed-key-file -` with `SPARKLE_ED_PRIVATE_KEY` when set, falling back to the login keychain.

- [x] **Write `.github/workflows/release-macos.yml`.**
      Tag-triggered. Import the Developer ID `.p12` from a base64 secret into a temporary keychain —
      all four `security` calls are required, and omitting `set-key-partition-list` makes `codesign`
      return `errSecInternalComponent` because it tries to raise a GUI prompt. Then run `release.sh`
      in strict mode, sign the appcast, and attach the DMG + `appcast.xml` + `SHA256SUMS` to the
      GitHub Release. Prefer an **App Store Connect API key** over an app-specific password: it is
      revocable independently of the Apple ID and survives password and 2FA changes.
      Secrets needed: `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`,
      `NOTARY_ISSUER_ID`, `NOTARY_KEY_ID`, `NOTARY_KEY_P8_BASE64`, `SPARKLE_ED_PRIVATE_KEY`.
      **Done.** Tag-triggered: imports the Developer ID `.p12` into a temporary keychain (all four `security` calls, including `set-key-partition-list`), stages the App Store Connect API key, runs `release.sh` with `SIDEWIRE_STRICT=1` and `SIDEWIRE_APPCAST=1`, re-verifies `stapler validate` + `spctl` independently, writes `SHA256SUMS`, publishes the release with `gh release create --verify-tag`, and deletes the keychain in an `always()` step. *Never executed* — use `workflow_dispatch` against a throwaway tag first.

- [x] **No GitHub-release publishing exists anywhere.** There is no `gh release`, no upload step —
      "upload the DMG and appcast to the Release" is currently a human action in every document.
      **Done.** `gh release create` in `release-macos.yml` uploads the DMG, `appcast.xml` and `SHA256SUMS`.

### Versions

- [x] **Version desync produces a wrongly-named DMG.**
      `package.json` and `landing/package.json` say `1.0.0`; [`app/project.yml:16`](app/project.yml)
      says `MARKETING_VERSION: "1.0"`. `release.sh` reads the latter, so the artifact is
      `Sidewire-1.0.dmg` — the exact defect `app/docs/09-next-stage.md` marks as `[done]`.
      Running any `pnpm version:*` fixes it as a side effect, but set it to `1.0.0` explicitly.
      **Done.** `MARKETING_VERSION` is `1.0.0`.

- [x] **The Rust crate is outside the "one version drives everything" system.**
      [`Cargo.toml:12`](app/clients/sidewire-viewer/Cargo.toml) is `0.1.0` and `release.mjs` never
      touches it, so any `sidewire-viewer-vX.Y.Z` artifact would carry a version the release tooling
      does not manage. Either add it to `TARGETS` or document that the client versions separately.
      **Done.** `release.mjs` now rewrites `[workspace.package] version` and refreshes `Cargo.lock`, and both are included in the release commit. Verified by dry run: all four version sources move together.

- [ ] **The first changelog will span the entire history.**
      `lastTag()` returns null with no tags, so the range becomes `HEAD` and the first
      `pnpm version:*` writes a section covering all 53 commits. Either hand-write the first
      `CHANGELOG.md` entry, or create a `v0.0.0` baseline tag before the first real bump.

### Licensing

- [ ] **Resolve the ffmpeg licence question before shipping any Rust binary.**
      Homebrew's `ffmpeg@7` — the build `app/README.md` tells you to install — is
      `GPL-3.0-or-later` (`--enable-gpl --enable-version3`). Every crate declares `license = "MIT"`
      and the landing page says "MIT-licensed". Publishing *source* creates no obligation, so this
      does not block going public; distributing a binary linked against that build would relicense
      the result under GPLv3. The fix is cheap: H.264 and HEVC **decoders** are native LGPL-2.1
      ffmpeg code needing no external library, so build with
      `--disable-gpl --disable-nonfree --disable-version3 --enable-decoder=h264,hevc`.
      *Unverified:* the claim that Debian/Ubuntu and gyan.dev builds are all GPL — only Homebrew's
      was actually checked. vcpkg's ffmpeg port is LGPL by default, which contradicts the sweeping
      version of that claim.

- [x] **Add `THIRD-PARTY-LICENSES.md`.**
      `Cargo.lock` resolves 323 crates. `swift-crypto`, `swift-certificates` and `swift-asn1` are
      Apache-2.0 and carry a NOTICE-propagation obligation for redistributed binaries; `ring` has a
      non-standard licence with BoringSSL-derived portions. Generate it mechanically with
      `cargo about`, and add `cargo deny check licenses` to CI so a new GPL/AGPL transitive
      dependency fails the build rather than surprising you at release time.
      **Done.** Generated from `cargo metadata` and the SPM pins.

### Security

- [x] **Unauthenticated LAN denial of service.**
      [`TCPListener.swift:170`](app/Packages/SidewireCore/Sources/SidewireCore/TCPListener.swift)
      hands the connection to `onConnection` at TCP *accept*, and
      [`DisplayController.swift:273`](app/Sidewire/Roles/Display/DisplayController.swift) immediately
      calls `closeSession(reason: .superseded)` — before TLS, before CPace. So
      `while true; do nc <display-ip> 5005; done` from anywhere on the LAN tears down a live session
      in a loop, with no certificate and no PIN. The pairing rate limiter does not apply: it is only
      consulted in `handlePairMsg`. **Fix:** hold the incoming transport aside, let it reach TLS
      ready *and* complete CPace, and only then close the incumbent. Also cap concurrent
      un-authenticated accepts. This will be the first thing a security-minded reader tries.
      **Done.** An accepted connection is now held in `pendingSessions` and cannot touch any state; `Session.onAuthenticated` fires only after CPace succeeds or an existing pin matches, and only then does `promote(_:)` displace the incumbent. Opening the main window also moved behind that gate. Un-authenticated connections are capped at four.

- [x] **Close the second fail-open path in `Session`.**
      [`Session.swift:274`](app/Packages/SidewireCore/Sources/SidewireCore/Session.swift):
      `guard let pairing = pairingConfig, let tls = tlsPeerInfo else { beginApplicationHandshake(); return }`
      — if either is nil the session skips CPace and pinning entirely. The only thing keeping that
      unreachable is [`TCPTransport.swift:131`](app/Packages/SidewireCore/Sources/SidewireCore/TCPTransport.swift).
      No test asserts that a nil-identity transport is refused, so one refactor separates this from
      silently granting unauthenticated sessions. Add the test, then make the guard fail closed.
      **Done.** The `pairingConfig`/`tlsPeerInfo` guard is split: no pairing config still proceeds (unit-test harnesses), but a pairing link with no TLS peer info now closes with `BYE(auth)` instead of skipping CPace and pinning.

- [x] **`LocalIdentity.shared` crashes the app on any keychain failure.**
      [`LocalIdentity.swift:55`](app/Packages/SidewireCore/Sources/SidewireCore/LocalIdentity.swift)
      calls `fatalError` inside a lazy static initialiser, and it is reached on every Display start.
      A locked or access-denied keychain becomes a hard crash with no user-facing error.
      **Done.** `shared` is now optional, backed by a `Result` that retains the error as `sharedFailure`. All four call sites guard and surface a user-facing message instead of crashing.

- [x] **Pin Sparkle to an exact version.**
      [`app/project.yml:59`](app/project.yml) declares `from: 2.0.0` — an open upper bound on the
      app's only network-facing component — and the app target's `Package.resolved` lives inside the
      gitignored `.xcodeproj`, so nothing pins it. A signed, notarized release would ship whatever
      SPM happened to resolve that day. Use `exactVersion` (or commit a resolved file).
      **Done.** `exactVersion: 2.9.5`. This mattered more than it looked: Sparkle had already drifted 2.9.4 → 2.9.5 on its own between audit and fix.

---

## P2 — Blocks calling it 1.0

### The macOS app

- [ ] **The app target has zero tests.** *(Partial: the security logic behind the DoS fix is now
      covered in `SidewireCoreTests` — five tests asserting that `onAuthenticated` fires only after
      a proof, stays shut on a wrong PIN and on a connection that proves nothing, still fires on a
      paired reconnect where nothing is newly pinned, and that a pairing link with no TLS context
      fails closed. Each was mutation-tested: they fail against the pre-fix behaviour. What remains
      uncovered is the SwiftUI/controller layer itself, which needs a test target and some
      dependency injection.)* `app/project.yml` declares exactly one target. The 34 Swift
      files under `app/Sidewire/` — role controllers, virtual display, presenter, every SwiftUI view
      — have no coverage. The DoS above lives in precisely that untested layer. Add a test target.

- [ ] **The private `CGVirtualDisplay` classes are bound as hard undefined symbols.**
      `nm -u` on the built binary shows four undefined ObjC class symbols. dyld binds those at image
      load, not lazily, so a macOS release that removes them makes the app fail to launch with
      `Symbol not found` — and that hits the **Display** role too, which never creates a virtual
      display, because the symbols live in the same binary. Resolve them with `NSClassFromString`
      and degrade gracefully to "virtual display unavailable on this macOS version".

- [ ] **Swift 6 is advertised but never applied.** `SWIFT_VERSION: "5.0"`; both packages are
      `swift-tools-version:5.9` with no `swiftLanguageMode` and no `StrictConcurrency`, while the
      README says "developed on Xcode 26 / Swift 6". The build is warning-free *in Swift 5 mode* —
      no data-race checking has ever been applied to this fairly concurrent code.
      **Measured, not migrated.** Built with `SWIFT_STRICT_CONCURRENCY=complete` on a clean tree:
      `SidewireProtocol` **0** warnings, `SidewireCore` **14**, the app target **98**
      concurrency-related (155 warnings in total), several of them explicitly *"this is an error in
      the Swift 6 language mode"*. So this is genuine work, not a flag flip — the recurring shapes
      are `reference to captured var 'self' in concurrently-executing code` (Session, Reconnector,
      Discovery), main-actor properties touched from nonisolated contexts (InputCapture), and
      non-Sendable access from `deinit` (AppModel). Deliberately not attempted while preparing a
      release: it touches the concurrency-critical paths the product depends on. Do it as its own
      change, package-first (Protocol is already clean, Core is 14 warnings away), then the app.
      Until then the README should not claim Swift 6.

- [x] **`swift test` in `SidewireCore` dirties the working tree.** It rewrites
      `app/Packages/SidewireCore/Package.resolved` to drop a stale `sparkle` pin that does not belong
      there (`Package.swift` never mentions Sparkle). Every contributor's first test run produces a
      spurious diff. Fix the checked-in file.
      **Done, and the original diagnosis was incomplete.** The file does not merely hold a stale pin — it oscillates: `swift test` resolves the package alone and drops Sparkle, `xcodebuild` resolves the whole project and writes it back, so *whichever* version is committed leaves someone with a spurious diff. It is a library's resolved file, which SwiftPM ignores in consumers, so it is now untracked. The app's real lock is the exact Sparkle pin.

- [x] **Review the `--vd-helper` re-exec path.** `app/Sidewire/App/main.swift` dispatches on a bare
      `CommandLine.arguments.contains("--vd-helper")` with no ancestry check, and
      `VirtualDisplayManager` re-execs the app's own binary with it. The app is deliberately
      unsandboxed. That combination deserves a deliberate look.
      **Reviewed — not a privilege boundary.** The helper runs as the same user with the same rights as the app, creates the same virtual display, and is driven over a private pipe; anyone able to invoke the binary with arguments can already run the app. There was a real *correctness* bug though: the dispatch used `arguments.contains("--vd-helper")`, which would also match a stray occurrence (a file path, a Launch Services argument) and silently start a headless helper where the user expected the app. Now checks the first argument specifically.

- [ ] **Reconsider the bundle identifier.** `com.kinocoder.sidewire` matches neither the repo name
      nor any signing identity, and it is baked into TCC grants and keychain item tags — changing it
      after release is disruptive, so decide now.

### The Rust client

- [x] **Drop four unused ffmpeg libraries.**
      [`Cargo.toml:32`](app/clients/sidewire-viewer/Cargo.toml) is `ffmpeg-the-third = "3"` with
      default features, so the binary links **seven** ffmpeg libraries (`otool -L`), not the three
      the packaging doc assumes. `avdevice` is the worst: it drags in v4l2/ALSA/X11-grab and
      dshow/gdigrab into a program that never opens a capture device. Verified working replacement:
      `{ version = "3", default-features = false, features = ["codec", "format", "non-exhaustive-enums"] }`
      — note `["codec"]` alone does **not** compile (the packet module references
      `av_interleaved_write_frame` ungated), so `format` must stay.
      **Done.** Verified with `otool -L`: seven libraries → three (`libavcodec`, `libavformat`, `libavutil`), tests still green. A CI gate now fails if the count grows again.

- [x] **Show the pairing PIN in the window.**
      [`main.rs:242`](app/clients/sidewire-viewer/sidewire-viewer/src/main.rs) prints it only to
      stdout, and `packaging/sidewire-viewer.desktop` sets `Terminal=false` — so a user who installs
      the AppImage and launches it from the applications menu gets a window and no PIN, and the app
      is unusable. On Windows the mirror image: with no `#![windows_subsystem = "windows"]` a console
      pops up next to the video window, and adding the attribute hides the PIN exactly as on Linux.
      Render it as an overlay in the pre-connection idle state.
      **Partially addressed.** The real fix (rendering the PIN in the winit window) is still open. As an honest stopgap the `.desktop` file now sets `Terminal=true`, so a menu-launched Linux install is at least usable instead of showing a window with no way to learn the PIN. Flip it back once the overlay exists.

- [ ] **Nothing in `packaging/` produces an artifact.** Three files, all packaging steps are
      `echo "TODO"`, and `ci-release.yml` still uses pre-monorepo paths (`clients/sidewire-viewer`
      rather than `app/clients/sidewire-viewer`). Missing for Windows: a WiX `Product.wxs`, an
      `.ico`, a version-info resource, an application manifest, an upgrade GUID. Missing for Linux:
      `[package.metadata.deb]`, an icon, an AppDir assembly script, an AppStream `metainfo.xml`.
      Suggested artifact set: Windows `.zip` + `.msi`, Linux AppImage + Flatpak. Flathub is worth a
      look — its runtime ships LGPL ffmpeg, which would dissolve the licensing problem outright.

- [ ] **Add a CI gate that reads the real dependency list off the binary.**
      `ldd` / `dumpbin /dependents` / `otool -L`, failing if any non-system library is missing from
      the bundle. Hand-maintained lists go stale on every ffmpeg bump.

- [x] **No MSRV enforcement.** `rust-version = "1.90"` is declared, there is no
      `rust-toolchain.toml`, and local rustc is 1.97.1 — so the claim has never been tested.
      **Done.** A separate `msrv` CI job runs `cargo check` on exactly 1.90, so the declared MSRV is verified rather than asserted. Kept out of the main `rust` job so a break is legible on its own. *Whether 1.90 actually compiles this tree is still unknown* — no local toolchain that old exists here, which is the entire point of the job.

- [ ] **Cross-compilation was never attempted.** The "not shippable" verdict rests on `packaging/`
      being empty, not on a failed build. Build natively per OS; `cross`/`cargo-zigbuild` are
      impractical here because of ffmpeg headers and libclang.

### The landing site

- [ ] **Every download and source CTA points at a repository that returns 404.**
      11 links to `github.com/lunindev/sidewire` across `Nav`, `Hero`, `HowItWorks`, `CTA`,
      `CrossPlatform`, `Footer` and `404`, from [`site.ts:13-15`](landing/src/data/site.ts).
      *Unverified:* checked through a proxied sandbox, so re-check from a normal network.

- [ ] **`site: 'https://sidewire.app'`** ([`astro.config.mjs:9`](landing/astro.config.mjs)) does not
      resolve. It drives canonical URLs, the sitemap and the absolute `og:image` URL — so link
      previews render with no image. Three places must change together: `astro.config.mjs`,
      `site.ts`, and the `Sitemap:` line in `public/robots.txt` (nothing derives robots.txt from
      `site`).

- [x] **Copy that outruns the product.** "Download for macOS" with no release and no notarized
      build; a whole Windows/Linux section presented as shipping when no binary has ever been built.
      Re-frame as "Coming next" until the artifacts exist.
      **Done.** Windows/Linux is now future tense with a "Coming next" badge, the download CTAs read "Watch for the v1 release", and a new FAQ answers "Where do I download it?" honestly.

- [x] **"Discovers Macs on the LAN" is backwards.**
      [`CrossPlatform.astro:31`](landing/src/components/CrossPlatform.astro) — the Rust client is
      always the Display, so it *advertises* `_sidewire._tcp` and the Mac browses for it.
      `--discover` exists only as a diagnostic.
      **Done.** Now "Announces itself on the LAN". A second factual error surfaced in the same component and was fixed too: "GPU-accelerated decode" — decode is *software* (libavcodec); only the YUV→RGB conversion and present are on the GPU.

- [x] **No mobile navigation at all.**
      [`Nav.astro:97`](landing/src/components/Nav.astro) hides `.nav-links` below 760px with no
      replacement — on every phone the four primary nav items simply vanish. A `<details>`-based
      menu needs no JavaScript and is keyboard-accessible for free, matching the site's no-JS stance.
      **Done.** A `<details>`-based disclosure menu below 760px, no JavaScript.

- [x] **The primary button fails WCAG AA.**
      [`global.css:201`](landing/src/styles/global.css) sets `#06121b` on a
      `#22d3ee → #6366f1` gradient. At the indigo end that is ~4.27:1 at 15.7px/600 — below the
      4.5:1 threshold, on the single most important element, repeated five times.
      **Done.** The failing element was the gradient's indigo stop, not the text: `--indigo` `#6366f1` → `#7276f4` takes the worst point from 4.24:1 to 5.06:1. A new `--ink-on-accent` token replaced four hardcoded copies, so every `--accent-grad` surface is fixed at once. Independently re-verified.

- [x] **No skip-to-content link.** Focus styling is otherwise deliberate, so this is an isolated gap.
      **Done.**

- [x] **No structured data.** The FAQ is already semantic `<details>/<summary>` driven by typed data,
      so a `FAQPage` block is nearly free; the spec table is a textbook `SoftwareApplication`.
      **Done.** `FAQPage` and `SoftwareApplication`, generated from the same typed data the page renders.

- [x] **Harden the container.** nginx runs its master as root, `server_tokens` is on, and there is no
      CSP or `Permissions-Policy` ([`nginx.conf:20`](landing/nginx.conf)). The site makes zero
      external requests — no web fonts, no CDN, no third-party scripts — so a near-maximally strict
      CSP would apply with no breakage. Switch to `nginxinc/nginx-unprivileged`. Remember the file's
      own note about nginx's `add_header` reset rule: repeat new headers inside the `/_astro/` block.
      **Done.** `server_tokens off`, a `default-src 'none'` CSP and a `Permissions-Policy`, repeated inside `/_astro/`; the image is now `nginx-unprivileged` on port 8080.

- [x] **Add privacy and terms pages, and link the licence.** The site makes strong privacy claims
      ("No accounts. No analytics. No telemetry.") that are actually true — Sparkle's appcast fetch
      is the only network call in the entire product. A short honest privacy page turns an
      unverifiable marketing line into the product's strongest differentiator.
      **Done.**

- [ ] **The "Docs" CTA leads to the internal engineering docs**, which is where the honest
      self-assessment lives. Either point it somewhere user-facing or accept that visitors will read
      "not yet notarized" immediately after clicking "Download".

- [ ] **Decide where the landing is deployed.** GitLab CI is the only pipeline and it has never run.
      On GitHub it is inert. GitHub Actions + Pages, or Cloudflare, or keep the container — but pick
      one, because right now nothing ships the site.

- [x] **Remove the dead `public/og.svg`.** It is built into the image and referenced by nothing;
      `Base.astro` uses `og.png`.
      **Done.**

---

## P3 — Deferred

- [ ] Hardware decode in the Rust client (a `DecodeBackend` seam already exists).
- [ ] Re-enable the `CGVirtualDisplay` helper subprocess, or accept in-process creation and delete
      the disabled path.
- [ ] Additional locales — the String Catalog is scaffolded, so this is translation, not engineering.
- [ ] Windows Authenticode signing. Without it SmartScreen warns on every download. An OV certificate
      builds reputation slowly; EV grants it immediately but costs more and needs a hardware token
      or a cloud HSM for CI. Reasonable to defer for a first release *if the README says so*.
- [ ] Supply-chain hardening proportionate to a solo project: pinned action SHAs, Dependabot,
      `cargo audit`, `SHA256SUMS` on release assets. Skip SLSA provenance and cosign for now.
- [ ] Rewrite `app/docs/07-roadmap-and-phases.md`, which still describes the phases as originally
      planned rather than as they shipped.

---

## 🔒 Owner-gated — needs credentials, hardware, or a decision

- [ ] **Test on two physical Macs.** The single largest risk, and not closable by writing code.
      Cover: first-time PIN pairing; paired reconnect skipping the PIN; a wrong PIN; **Forget this
      Mac** then re-pair; cable-pull and sleep/wake recovery on both sides; an Intel Mac as Source
      (the H.264 encoder-fallback path); both Thunderbolt and Wi-Fi; a session of an hour or more.

- [ ] **Prove live Rust↔Swift interop.** Only Rust↔Rust loopback and the golden vectors have been
      exercised. Check first that the Rust `device_id` (SHA-256 of the DER SubjectPublicKeyInfo,
      first 16 bytes) matches what swift-crypto computes for the same key — currently cross-checked
      only against the OpenSSL CLI.

- [ ] **Generate the Sparkle EdDSA key** and paste the public half into `SUPublicEDKey`
      ([`Info.plist:38`](app/Sidewire/Resources/Info.plist)). Export the private half with
      `generate_keys -x` for the CI secret, then delete the file. Until a real key is set Sparkle
      fails closed, which is the safe default — but it also means `release.sh` refuses to run.

- [ ] **Choose the GitHub owner and set `SUFeedURL`** ([`Info.plist:32`](app/Sidewire/Resources/Info.plist),
      currently `github.com/OWNER/sidewire`). It must match what the landing page already hardcodes,
      or Sparkle will 404 on every update check.

- [ ] **Create the App Store Connect API key** and store the seven release secrets.

- [ ] **Register the production domain** or change the origin everywhere it appears.

- [ ] **Set the repository description and topics** on GitHub — free discovery, usually forgotten.

---

## Open questions

Things that need a decision, not an implementation.

1. **Which GitHub owner and repository name?** The landing hardcodes `lunindev/sidewire` and the
   bundle prefix is `com.kinocoder`, but nothing else confirms it.
2. **Is the private `CGVirtualDisplay` dependency acceptable long-term?** It rules out the App Store
   permanently and can break on any macOS release. Everything else is a consequence of this choice.
3. **Ship Windows and Linux at 1.0, or macOS first?** Shipping macOS alone is much less work and the
   landing already oversells the alternative.
4. **Static or dynamic ffmpeg?** Static gives one self-contained binary but triggers LGPL §6
   (you must ship relinkable objects or sources). Dynamic is the conventional answer.
5. **Does a "pro" tier still matter?** `app/docs/08` records an intent to keep a future closed tier
   possible, which shapes both the licence choice and contributor expectations — say so publicly or
   drop the note.
6. **Is `alex@lunin.dev` the right identity on 53 public commits?** It is not a secret, but it does
   become permanently public and machine-readable. Changing it means another rewrite, so decide now.
7. **Keep publishing `app/docs/00`–`10`?** They are genuinely good and a differentiator, but they
   also document every known weakness. My view: publish them — the honesty reads as rigour.

---

## Before the first push, verify

Run these and expect silence:

```bash
# No Cyrillic anywhere in the working tree. Use ripgrep — `git grep -P '\p{Cyrillic}'`
# silently returns ZERO in a C locale, which is how CI usually runs.
git ls-files -z | xargs -0 rg -l '\p{Cyrillic}'

# No personal data.
git grep -nIE '[A-Za-z0-9._%+-]+@(gmail|yandex|mail|outlook|icloud)\.[A-Za-z]{2,}|/Users/[a-z]+/'

# No dead internal links.
git grep -n '11-handoff\|12-remaining'

# The documented build works from a clean state.
cd app && rm -rf Sidewire.xcodeproj && xcodegen generate && \
  xcodebuild -project Sidewire.xcodeproj -scheme Sidewire -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/dd build
```

To scan the whole history rather than just the working tree, iterate every blob with
`git rev-list --objects --all` + `git cat-file`, and decode as UTF-8 so binary files are skipped
rather than producing false positives. Whatever guard you write, test it against a known-Cyrillic
fixture first — a silently broken matcher is worse than no matcher.

---

## Reference — what the numbers actually are

Documentation drift caused several wrong figures. These were measured, not quoted:

| Suite | Actual | Previously documented |
| --- | --- | --- |
| `Packages/SidewireProtocol` | 40 | 24 |
| `Packages/SidewireCore` | 39 | 39 ✓ |
| Rust workspace | 80 (+1 `#[ignore]`d) | 74 |

Repository: 53 commits, linear, no merges, one branch, no tags, `.git` ≈ 1.2 MB, no file over
134 KB, and no build artifact has ever been committed.
