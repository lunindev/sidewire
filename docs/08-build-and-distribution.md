# 08 — Build & Distribution

Implemented in Phase 5, but the identity decisions (bundle id, no sandbox) are set in Phase 0 and must not change later. The owner already has an Apple Developer ID, so signing/notarization is straightforward. Read [00 D1/D8](00-review-and-decisions.md).

> **Implemented.** The whole distribution flow is scripted in [`scripts/release.sh`](../scripts/release.sh): it builds Release with **Developer ID Application: <Your Name> (<YOUR_TEAM_ID>)** signing + **hardened runtime** + a secure timestamp (an override that never touches the dev Apple Development signing), verifies the signature, builds a drag-install DMG (app + `/Applications` symlink), then notarizes + staples both the app and the DMG. Notarization needs a one-time `xcrun notarytool store-credentials sidewire-notary …` (app-specific password) that the owner runs — the script uses the resulting keychain profile and never sees the password. Bundle id is `com.kinocoder.sidewire`; version keys live in `Info.plist` as `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`. Verified locally: signs cleanly with the runtime flag set and launches (hardened runtime does not break the private `CGVirtualDisplay` API or the helper re-exec); Gatekeeper reports "Unnotarized Developer ID" until the notarize step runs. See the top-level [README § Distribution & notarization](../README.md#distribution--notarization) for the exact commands.

## The hard facts

- **Mac App Store is impossible** — App Review rejects the private `CGVirtualDisplay` API and `CGEvent` input injection. This is permanent and not worth revisiting.
- **Notarization is fine** — Apple's notary is an automated malware/signature scan, **not** an API-policy check. It does not flag the private API. This is how BetterDisplay, DeskPad, Lumen, and FluffyDisplay all ship. (FluffyDisplay is even notarized *and* sandboxed while using the same private CoreGraphics APIs.)
- **Do NOT App-Sandbox.** The sandbox is incompatible with both the private display API and `CGEvent` injection. Keep the **hardened runtime** (required for notarization) with a minimal entitlements set.

## Identity (fix once, forever)

- **One bundle identifier** for the life of the product (e.g. `com.sidewire.app`) and **one Developer ID Application** signing identity. TCC (Screen Recording, Accessibility) grants key on the code-signing identity + bundle id; changing either forces every user to re-grant permissions — a bad regression. The current unsigned-from-Xcode build loses permissions on every rebuild precisely because it lacks a stable identity; a stable Developer ID fixes that.
- The `SidewireDisplayHelper` gets its own stable bundle id under the same team, signed the same way.

## Build — Universal 2

- `ARCHS = arm64 x86_64` so one binary runs natively on the M4 Max (Source) and the Intel i9 (Display). Verify with `lipo -archs`. Every dependency (Sparkle, any SwiftPM lib) must also be universal.
- Deployment target macOS 14.0. Accept the ~2× Mach-O size — trivial next to nothing else here.

## Entitlements

Hardened runtime, minimal set. Likely needed:
- (nothing for screen capture — there is **no** "screen-capture" entitlement; capture is gated by TCC prompts at runtime).
- `com.apple.security.cs.disable-library-validation` **only if** third-party unsigned code is dynamically loaded (avoid if possible).
- Sign the helper and any Sparkle XPC services individually, in the correct order; **never `codesign --deep`** (it corrupts Sparkle's XPC signatures).
- `Info.plist`: `NSLocalNetworkUsageDescription`, `LSUIElement = YES`, and the usage strings for Screen Recording / Accessibility flows.

## Signing → Notarization → Stapling pipeline

```
xcodebuild -project Sidewire.xcodeproj -scheme Sidewire \
           -configuration Release -archivePath build/Sidewire.xcarchive archive
xcodebuild -exportArchive -archivePath build/Sidewire.xcarchive \
           -exportOptionsPlist ExportOptions.plist \
           -exportPath build/export          # method = developer-id
create-dmg ... build/export/Sidewire.app     # polished drag-to-Applications DMG
xcrun notarytool submit build/Sidewire.dmg \
           --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
           --password "$APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple build/Sidewire.dmg      # REQUIRED — offline first-launch fails without it
spctl -a -t open --context context:primary-signature -vv build/Sidewire.dmg   # verify
```

Notes:
- `notarytool` needs an **app-specific password** (not the Apple ID password); `altool` is deprecated.
- **Forgetting to staple** means Gatekeeper fails on the first offline launch even though notarization succeeded — a classic, silent mistake.

## CI (GitHub Actions)

> **Implemented (Phase 9).** Two workflows under [`.github/workflows/`](../../.github/workflows/):
> - **`ci.yml`** — build + test on every push/PR (`macos-14`): `brew install xcodegen`, run **both** package suites (`Packages/SidewireProtocol` = 24 tests, `Packages/SidewireCore` = 39 tests), `xcodegen generate`, then a Debug `xcodebuild` with signing **disabled** (`CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`) — the runner has no Apple cert, so this only proves the code compiles, Sparkle links, and its XPC services embed. This one is real and runnable.
> - **`release.yml`** — a **documented sketch** (`workflow_dispatch`, **never run**) for the signed path: import the Developer ID `.p12` from a base64 secret into a temp keychain, `store-credentials` for notarytool, run `scripts/release.sh`, generate + EdDSA-sign the appcast, and publish the DMG + `appcast.xml` to a GitHub Release. It is a starting point that needs the owner's secrets — see the header comment in the file for the full secret list.

- Store the Developer ID `.p12` base64-encoded in a repo secret; on CI, create a temporary keychain, import, build, sign, notarize, staple. Store the EdDSA update key as a separate secret (or sign releases manually).
- Artifacts: the stapled DMG + the Sparkle appcast entry, published to GitHub Releases.

## Auto-update — Sparkle 2

> **Implemented (Phase 9).** Sparkle 2 (resolves as **2.9.4** via SPM from `2.0.0`) is integrated as the app's auto-updater. Wiring: [`project.yml`](../project.yml) adds the `Sparkle` package + a `- package: Sparkle` dependency (Xcode embeds + signs `Sparkle.framework` and its `Downloader.xpc` / `Installer.xpc` inside-out automatically — **no `--deep`**, verified with `codesign --verify --strict`). [`Sidewire/App/UpdaterController.swift`](../Sidewire/App/UpdaterController.swift) is a `@MainActor ObservableObject` wrapping `SPUStandardUpdaterController(startingUpdater: true, …)`, held as a `@StateObject` in `SidewireApp`; a **"Check for Updates…"** command (`CommandGroup(after: .appInfo)`, `.disabled(!canCheckForUpdates)`) sits under the app menu, and it is mirrored in the menu-bar window so it stays reachable in menu-bar-only mode. A Settings **"Automatically check for updates"** toggle binds `updater.automaticallyChecksForUpdates`.
>
> **Info.plist keys** ([`Sidewire/Resources/Info.plist`](../Sidewire/Resources/Info.plist)): `SUFeedURL` (`…/OWNER/sidewire/releases/latest/download/appcast.xml` — owner sets the real owner), `SUPublicEDKey` (placeholder `REPLACE_WITH_SUPublicEDKey_FROM_generate_keys`), `SUEnableAutomaticChecks = false` (opt-in). **Until `SUPublicEDKey` is a real key, Sparkle fails closed** — it refuses any update it can't verify, the safe default.
>
> **Owner one-time step:** run Sparkle's `generate_keys` once (ships in the resolved SPM artifact at `<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/`), keep the **private** key in the login keychain, paste the printed **public** key into `SUPublicEDKey`. Then per release: `./scripts/release.sh` builds+notarizes the DMG and [`scripts/generate-appcast.sh`](../scripts/generate-appcast.sh) EdDSA-signs it into `appcast.xml`; upload both to the GitHub Release. `release.sh` prints this reminder (or runs generate-appcast itself if invoked with `SIDEWIRE_APPCAST=1`).

- Sparkle 2 with **EdDSA (Ed25519)** signatures. Host the `appcast.xml` + DMGs on GitHub Releases (free).
- Increment `CFBundleVersion` every build (Sparkle keys update detection on it). It is already `$(CURRENT_PROJECT_VERSION)` in Info.plist.
- Leave Sparkle's XPC service bundle ids untouched; sign components in order; no `--deep`.
- Guard the EdDSA private key custody (CI secret vs manual release signing) — a leaked update key lets an attacker ship a malicious "update."
- **Sparkle is the app's first and only network "phone-home."** The product is otherwise 100 % local — no accounts, no telemetry, no HTTP anywhere else in the code. Keep it that way; the Settings copy and README say so to the user.

## Licensing

- Ship under a **permissive license (MIT or Apache-2.0)** to keep a future closed "pro" tier possible.
- **Never lift code** from AGPL (Deskreen) or GPL (Moonlight/Sunshine) projects — reference their *behavior* only. This is set at the start, not retrofitted.

## Private-API risk management (distribution angle)

- Isolate `CGVirtualDisplay` behind the one bridge ([04 § Virtual Display](04-media-pipeline.md#virtual-display)); keep the mirror-only/clear-error fallback so an OS update can degrade the app rather than brick it.
- Test against **every macOS beta** — the Tahoe HiDPI regression is the current reminder that per-release behavior changes even when the API shape is stable.
