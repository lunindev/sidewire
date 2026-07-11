# 08 — Build & Distribution

Implemented in Phase 5, but the identity decisions (bundle id, no sandbox) are set in Phase 0 and must not change later. The owner already has an Apple Developer ID, so signing/notarization is straightforward. Read [00 D1/D8](00-review-and-decisions.md).

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

- Store the Developer ID `.p12` base64-encoded in a repo secret; on CI, create a temporary keychain, import, build, sign, notarize, staple. Store the EdDSA update key as a separate secret (or sign releases manually).
- Artifacts: the stapled DMG + the Sparkle appcast entry, published to GitHub Releases.

## Auto-update — Sparkle 2

- Sparkle 2 with **EdDSA (Ed25519)** signatures. Host the `appcast.xml` + DMGs on GitHub Releases (free).
- Increment `CFBundleVersion` every build (Sparkle keys update detection on it).
- Leave Sparkle's XPC service bundle ids untouched; sign components in order; no `--deep`.
- Guard the EdDSA private key custody (CI secret vs manual release signing) — a leaked update key lets an attacker ship a malicious "update."

## Licensing

- Ship under a **permissive license (MIT or Apache-2.0)** to keep a future closed "pro" tier possible.
- **Never lift code** from AGPL (Deskreen) or GPL (Moonlight/Sunshine) projects — reference their *behavior* only. This is set at the start, not retrofitted.

## Private-API risk management (distribution angle)

- Isolate `CGVirtualDisplay` behind the one bridge ([04 § Virtual Display](04-media-pipeline.md#virtual-display)); keep the mirror-only/clear-error fallback so an OS update can degrade the app rather than brick it.
- Test against **every macOS beta** — the Tahoe HiDPI regression is the current reminder that per-release behavior changes even when the API shape is stable.
