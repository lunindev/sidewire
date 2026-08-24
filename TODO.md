# TODO

What is left before Sidewire could reasonably be called released. Grouped by what each item blocks.

Everything carries enough context to be picked up cold. Claims that have not been verified are
marked as such — please do not treat them as facts until someone checks.

---

## Before anyone can rely on it

- [ ] **Test on two physical Macs.** The single largest risk, and not closable by writing code.
      Cover: first-time PIN pairing; a paired reconnect skipping the PIN; a wrong PIN; **Forget this
      Mac** then re-pair; cable-pull and sleep/wake recovery on both sides; an Intel Mac as Source
      (the H.264 encoder-fallback path); both Thunderbolt and Wi-Fi; a session of an hour or more.

- [ ] **Prove live Rust↔Swift interop.** Only Rust↔Rust loopback and the golden vectors have been
      exercised. Check first that the Rust `device_id` (SHA-256 of the DER SubjectPublicKeyInfo,
      first 16 bytes) matches what swift-crypto computes for the same key — it is currently
      cross-checked only against the OpenSSL CLI.

- [ ] **The app target has zero tests.** `app/project.yml` declares one target, so the SwiftUI
      views, role controllers and virtual-display code have no coverage at all. The security logic
      behind the pairing gate *is* covered, in `SidewireCoreTests` — five mutation-tested cases
      asserting that a connection which proves nothing never authenticates. What remains uncovered
      is the app layer, which needs a test target and some dependency injection.

- [ ] **The private `CGVirtualDisplay` classes are bound as hard undefined symbols.**
      `nm -u` shows four undefined ObjC class symbols, and dyld binds those at image load rather
      than lazily. A macOS release that removes them makes the app fail to launch outright — and it
      would hit the **Display** role too, which never creates a virtual display, because the symbols
      live in the same binary. Resolve them with `NSClassFromString` and degrade to a clean
      "virtual display unavailable on this macOS version".

## Before a release could be cut

- [ ] **Generate the Sparkle EdDSA key** and paste the public half into `SUPublicEDKey`
      ([`Info.plist`](app/Sidewire/Resources/Info.plist)). Until a real key is set Sparkle fails
      closed and refuses every update, which is the safe default — but it also means
      `scripts/release.sh` refuses to run.

- [ ] **Create an App Store Connect API key** for notarization, and export the Developer ID
      certificate. `scripts/release.sh` reads both from the environment
      (`SIDEWIRE_SIGN_IDENTITY`, `SIDEWIRE_TEAM_ID`, `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`,
      `NOTARY_ISSUER_ID`) and has a `SIDEWIRE_STRICT=1` mode that fails rather than quietly
      producing an unnotarized build.

- [ ] **The first changelog would span the entire history.** `lastTag()` returns null with no tags,
      so the range becomes `HEAD`. Either hand-write the first `CHANGELOG.md` entry or create a
      baseline tag before the first real bump.

- [ ] **Add a screenshot or a short GIF to the README.** There is not one image in any README. For
      a product whose whole pitch is *"a real second desktop"*, showing it is worth more than
      several paragraphs.

## The Rust client

- [ ] **Nothing in `packaging/` produces an artifact.** No WiX `Product.wxs`, no `.ico`, no
      version-info resource for Windows; no `[package.metadata.deb]`, no icon, no AppDir script or
      AppStream metainfo for Linux. A reasonable target set is Windows `.zip` + `.msi` and Linux
      AppImage + Flatpak — Flathub is worth a look, since its runtime ships an LGPL FFmpeg.

- [ ] **Show the pairing PIN in the window.** It is printed to stdout only, so a user who installs
      a packaged build and launches it from an applications menu gets a window and no way to learn
      the PIN. `sidewire-viewer.desktop` sets `Terminal=true` as an honest stopgap; render the PIN
      as an overlay in the pre-connection idle state and set it back to `false`.

- [ ] **Cross-compilation was never attempted.** The "not shippable" verdict rests on `packaging/`
      being empty, not on a failed build. Build natively per OS — `cross` and `cargo-zigbuild` are
      impractical here because of FFmpeg headers and libclang.

- [ ] **Document the FFmpeg build used for any published binary.** Sidewire is GPL-3.0-or-later, so
      linking a GPL FFmpeg is consistent — but distributing a binary carries a source-availability
      obligation for the combined work. Publish the exact `configure` line alongside each release.
      *Unverified:* whether Debian/Ubuntu and gyan.dev builds are GPL — only Homebrew's was checked.

- [ ] **Hardware decode** (VideoToolbox / D3D11VA / VAAPI). A `DecodeBackend` seam already exists.

## Quality

- [ ] **Swift 6 is never applied.** `SWIFT_VERSION` is 5.0 and both packages are
      `swift-tools-version:5.9` with no strict-concurrency setting. Measured under
      `SWIFT_STRICT_CONCURRENCY=complete` on a clean tree: `SidewireProtocol` 0 warnings,
      `SidewireCore` 14, the app target 98 — several of them errors in Swift 6 mode. Recurring
      shapes: `reference to captured var 'self' in concurrently-executing code`, main-actor
      properties touched from nonisolated contexts, non-Sendable access from `deinit`. Do it as its
      own change, packages first.

- [ ] **Re-enable the `CGVirtualDisplay` helper subprocess** — fix the ~3 s activation-timeout
      regression, or accept in-process creation and delete the disabled path.

- [ ] **Reconsider the bundle identifier.** `com.kinocoder.sidewire` matches neither the repository
      name nor any signing identity, and it is baked into TCC grants and Keychain item tags —
      changing it after release is disruptive, so decide now.

- [ ] **Additional locales.** The String Catalog is scaffolded, so this is a translation task.

- [ ] **Windows Authenticode signing.** Without it SmartScreen warns on every download. An OV
      certificate builds reputation slowly; EV grants it immediately but costs more and needs a
      hardware token. Reasonable to defer, *if the README says so*.

## The landing site

Not deployed anywhere, and nothing publishes it. These matter only if that changes.

- [ ] **Every download and source CTA points at a repository path that may not resolve.** Re-check
      each URL in `landing/src/data/site.ts` once the repository is public.

- [ ] **`site: 'https://sidewire.app'`** in `astro.config.mjs` does not resolve. It drives canonical
      URLs, the sitemap and the absolute `og:image` URL. Three places must change together:
      `astro.config.mjs`, `site.ts`, and the `Sitemap:` line in `public/robots.txt`.

- [ ] **The "Docs" link leads to the engineering documentation**, which is where the honest
      self-assessment lives. Either point it somewhere user-facing or accept that a visitor reads
      "never run on two physical Macs" immediately after clicking a download button.

- [ ] **Decide whether it is deployed at all.** The container builds and serves correctly with a
      strict CSP; there is simply no pipeline pushing it anywhere.

## Repository

- [ ] **Set the description and topics** on GitHub — free discovery, and usually forgotten.

- [ ] **Fill in the security contact** in [`SECURITY.md`](SECURITY.md), and enable GitHub's Private
      Vulnerability Reporting.

- [ ] **There is no CI.** Deliberate for now. If it is ever added, the gates worth having are: both
      Swift suites, a universal unsigned `xcodebuild`, `cargo fmt`/`clippy`/`test`, a check that the
      FFmpeg link set stays at three libraries, and an assertion that ad-hoc signing is never
      combined with the hardened runtime — that combination builds cleanly and crashes at launch.

---

## Already addressed

Recorded briefly, because the reasoning is easy to lose and some of these were subtle.

- **A Keychain certificate leak that could hang the whole machine.** The identity cache looked
  itself up by `kSecAttrLabel`, which macOS derives from the subject common name for certificates,
  so the lookup never matched: a fresh self-signed leaf was minted and stored on *every*
  initialisation and never cleaned up. Several hundred of them make `trustd` saturate a core, and
  everything that verifies a certificate queues behind it. The leaf is now built in memory and
  never stored; `KeychainHygieneTests` is the regression guard.
- **An unauthenticated denial of service.** Accepting a TCP connection superseded the live session
  before TLS and before the PAKE, so any host on the LAN could tear down a session in a loop with
  no PIN and no certificate. Connections are now held aside until authenticated.
- **An app that built cleanly and crashed at launch.** Ad-hoc signing has no Team ID; the hardened
  runtime enables Library Validation, so dyld refused to load the embedded Sparkle framework.
- **A lost close reason.** Dropping a socket with unread bytes makes the kernel send RST, which
  lets the peer discard the `BYE` written moments earlier, so a clean disconnect looked like a
  transport failure.
- **A release tag that could never reach a remote** (lightweight, while the documented push was
  `--follow-tags`), a release script that produced an unnotarized DMG and exited zero, and an undo
  script that could hard-reset published history.
- **A build that worked on exactly one machine** — the signing identity was pinned to a certificate
  hash present in a single keychain.
- **Four FFmpeg libraries the client never uses**, including the platform capture backends.
- **Documentation that claimed more than was true** — CI that did not exist, stale test counts, and
  a status section that led with "distributable-ready" thirteen lines above "never run on real
  hardware".
