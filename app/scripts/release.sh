#!/bin/bash
#
# Sidewire release pipeline: build → Developer ID sign (hardened runtime) → verify → DMG →
# notarize → staple. The everyday Xcode build keeps its Apple Development signing; this script
# overrides signing for distribution only, so it never disturbs the dev workflow / TCC grants.
#
# One-time setup (you, once — enters your Apple credentials, which this script never sees):
#   xcrun notarytool store-credentials sidewire-notary \
#       --apple-id "<your-apple-id-email>" --team-id "$SIDEWIRE_TEAM_ID" \
#       --password <app-specific-password from appleid.apple.com → App-Specific Passwords>
#
# Signing identity and team are read from the environment so this script carries no personal
# account details. Export them once in your shell profile (or pass them per invocation):
#   export SIDEWIRE_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
#   export SIDEWIRE_TEAM_ID="TEAMID"
#
# Then just:  ./scripts/release.sh
# Without notarization credentials it still builds+signs+DMGs and tells you what to run.
#
# In CI set SIDEWIRE_STRICT=1 so that missing credentials FAIL instead of quietly producing an
# unnotarized DMG, and pass an App Store Connect API key via NOTARY_KEY_PATH / NOTARY_KEY_ID /
# NOTARY_ISSUER_ID (no keychain profile needed). See § 3 below.
set -euo pipefail

# ---- config ----------------------------------------------------------------
IDENTITY="${SIDEWIRE_SIGN_IDENTITY:?set SIDEWIRE_SIGN_IDENTITY to your 'Developer ID Application: NAME (TEAMID)'}"
TEAM_ID="${SIDEWIRE_TEAM_ID:?set SIDEWIRE_TEAM_ID to your Apple Developer Team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-sidewire-notary}"
SCHEME="Sidewire"
APP_NAME="Sidewire"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/dist"
DD="$ROOT/build/release-dd"
STAGE="$OUT/stage"
APP="$OUT/$APP_NAME.app"

# The source Info.plist holds the literal $(MARKETING_VERSION), so read the real version
# from project.yml (single source of truth) instead.
VERSION="$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/')"
[ -n "$VERSION" ] || { echo "✗ Could not read MARKETING_VERSION from project.yml"; exit 1; }
DMG="$OUT/$APP_NAME-$VERSION.dmg"

check_sparkle() {
  local plist="$1" where="$2" key feed bytes
  key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)"
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null || true)"

  # Swift's Data(base64Encoded:) rejects embedded whitespace outright, so this must too. openssl
  # does NOT: it happily skips a stray space and reports 32 bytes. Without this check a key with
  # a trailing space — the most ordinary paste artifact there is — passes the gate and is then
  # refused by the app, i.e. a FALSE GREEN on the one check whose entire job is to stop a
  # silently-dead updater from shipping. Verified: "<key> " → openssl 32 bytes, Swift keyOK=false.
  case "$key" in
    *[[:space:]]*)
      echo "✗ SUPublicEDKey ($where) contains whitespace, so the app will reject it at runtime"
      echo "  even though it looks right. Put the key on one line with no spaces around it."
      exit 1;;
  esac
  # A real Ed25519 public key is base64 decoding to exactly 32 bytes. That single check covers the
  # "REPLACE_WITH…" placeholder, an empty key, and a truncated or typo'd paste alike.
  bytes="$(printf '%s' "$key" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
  if [ "$bytes" != "32" ]; then
    echo "✗ SUPublicEDKey ($where) is not a valid Ed25519 public key: decoded ${bytes:-0} bytes, expected 32."
    echo "  Found: ${key:-<missing>}"
    echo "  Run Sparkle's generate_keys once, keep the PRIVATE key in your login keychain, and paste"
    echo "  the printed PUBLIC key into Sidewire/Resources/Info.plist. Shipping without it means this"
    echo "  release can never be updated."
    exit 1
  fi
  case "${feed:-}" in
    ""|*github.com/OWNER/*)
      echo "✗ SUFeedURL ($where) is still the shipped placeholder: ${feed:-<missing>}"
      echo "  Replace OWNER in Sidewire/Resources/Info.plist with the real GitHub org/user hosting"
      echo "  the repo, or this release's users will never find an update."
      exit 1;;
  esac
}

echo "▸ Sidewire $VERSION → $DMG"

# ---- 0. preflight: fail before spending a whole build on an unconfigured tree ----
# The Sparkle values are plain literals the build copies through untouched (unlike
# $(MARKETING_VERSION), which it does resolve), so they can be judged from the source plist in a
# second rather than after several minutes of universal Release build. Step 1c re-checks the built
# bundle regardless — that is what actually ships, and it's the artifact that must be right.
#
# This MUST stay above the cleanup below. It used to run after it, so an unconfigured tree — the
# state every fresh clone is in — destroyed the previous release's DMG and appcast.xml on its way
# to failing, and took out the resolved SPM artifacts that generate-appcast.sh needs.
check_sparkle "$ROOT/Sidewire/Resources/Info.plist" "source plist"
echo "  ✓ Sparkle configured"

rm -rf "$OUT" "$DD"; mkdir -p "$OUT"

# ---- 1. regenerate + build (Developer ID + hardened runtime + secure timestamp) ----
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
echo "▸ Building Release (Developer ID, hardened runtime)…"
xcodebuild -project Sidewire.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build >/dev/null
cp -R "$DD/Build/Products/Release/$APP_NAME.app" "$APP"

# ---- 1b. assert a universal (arm64 + x86_64) binary — a broken slice must not ship ----
BIN="$APP/Contents/MacOS/$APP_NAME"
ARCHS_OUT="$(lipo -archs "$BIN" 2>/dev/null || true)"
[[ "$ARCHS_OUT" == *x86_64* && "$ARCHS_OUT" == *arm64* ]] \
  || { echo "✗ App binary is not universal (lipo -archs: '${ARCHS_OUT:-none}'); expected x86_64 + arm64"; exit 1; }
echo "  ✓ Universal binary ($ARCHS_OUT)"

# ---- 1c. assert auto-update is really configured ---------------------------
# The app fails CLOSED on a placeholder (UpdaterController.isConfigured), which is the safe
# default but also a silent one: a build shipped this way looks perfectly healthy and simply
# never updates. That is the one defect with no fix-forward — once a buyer installs 1.0 with a
# dead feed, no later release can reach them. Cheaper to fail here than to be unreachable.
#
# check_sparkle mirrors UpdaterController.swift:83/87. It is called TWICE — once on the source
# plist before the build (so a typo costs a second, not a full universal Release build) and once
# on the built bundle, which is what actually ships. One function, so the two cannot drift.
check_sparkle "$APP/Contents/Info.plist" "built bundle"
echo "  ✓ Sparkle configured (feed + EdDSA public key)"

# The appcast's enclosure URLs must point at the same owner the feed does, or Sparkle finds the
# update and 404s on the download. Derive it from the value just validated rather than let a
# second, independently-set variable disagree with it.
SU_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
SU_OWNER="$(printf '%s' "$SU_FEED_URL" | sed -nE 's#^https://github\.com/([^/]+)/.*#\1#p')"
[ -n "$SU_OWNER" ] && export SIDEWIRE_REPO_OWNER="${SIDEWIRE_REPO_OWNER:-$SU_OWNER}"

# ---- 1d. assert the app has an icon ----------------------------------------
# A generic-icon app in the Dock and on the DMG reads as unfinished before a single feature is
# tried. The asset catalog compiles to Contents/Resources/AppIcon.icns; no catalog, no Resources.
[ -f "$APP/Contents/Resources/AppIcon.icns" ] \
  || { echo "✗ No app icon: $APP/Contents/Resources/AppIcon.icns is missing."; \
       echo "  Check Sidewire/Resources/Assets.xcassets/AppIcon.appiconset and re-run xcodegen."; exit 1; }
echo "  ✓ App icon present"

# ---- 2. verify signature + hardened runtime ----
echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=4 "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier=$TEAM_ID|flags.*runtime" \
  || { echo "✗ Missing Developer ID authority / hardened runtime flag"; codesign -d --verbose=4 "$APP" 2>&1 | grep -E "Authority|flags|Team"; exit 1; }
echo "  ✓ Developer ID + hardened runtime"

# ---- helper: build the DMG from whatever is in $APP right now ----
make_dmg() {
  rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
}

# ---- 3. notarize (or stop with instructions) ----
# Credentials come from one of two places, in priority order:
#
#   1. An App Store Connect API key passed by environment (NOTARY_KEY_PATH / NOTARY_KEY_ID /
#      NOTARY_ISSUER_ID). This is the CI path: notarytool takes the key directly, so no keychain
#      profile and no interactive `store-credentials` is involved. It is also the better path
#      interactively — an API key is revocable on its own and survives Apple ID password and 2FA
#      changes, unlike an app-specific password.
#   2. A local `store-credentials` keychain profile, for a developer who already set one up.
#
# SIDEWIRE_STRICT=1 turns "no credentials" from a soft stop into a hard failure. CI MUST set it.
# Without it this script's friendly interactive behaviour — build the DMG anyway, explain, exit 0 —
# is exactly wrong on a runner: the job goes green, an UNNOTARIZED DMG is sitting in dist/, and the
# next step happily attaches it to a public release. Users then get Gatekeeper's "Apple cannot check
# it for malicious software" on a build that looks signed. Note the exit 0 below also sits above the
# Sparkle step, so that path produces no appcast.xml either — a release with no update feed at all.
NOTARY_ARGS=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_PATH is set, so NOTARY_KEY_ID must be too}"
  : "${NOTARY_ISSUER_ID:?NOTARY_KEY_PATH is set, so NOTARY_ISSUER_ID must be too}"
  [ -r "$NOTARY_KEY_PATH" ] || { echo "✗ NOTARY_KEY_PATH is not readable: $NOTARY_KEY_PATH"; exit 1; }
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  echo "  ✓ notarization via App Store Connect API key"
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  echo "  ✓ notarization via keychain profile '$NOTARY_PROFILE'"
elif [ "${SIDEWIRE_STRICT:-0}" = "1" ]; then
  echo "✗ SIDEWIRE_STRICT=1 and no notarization credentials are available."
  echo "  Set NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID (App Store Connect API key),"
  echo "  or create the '$NOTARY_PROFILE' keychain profile. Refusing to produce an unnotarized build."
  exit 1
else
  make_dmg
  cat <<EOF

▸ Built + signed, DMG created (NOT yet notarized):
    $DMG

⚠️  This DMG will be BLOCKED by Gatekeeper on any Mac that downloads it. It is fine for copying to
    your own machines, and not fine to publish.

To notarize, either set up an App Store Connect API key (recommended):
    export NOTARY_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
    export NOTARY_KEY_ID=XXXXXXXXXX
    export NOTARY_ISSUER_ID=<issuer-uuid from App Store Connect → Integrations>

…or create a keychain profile once from an app-specific password:
    xcrun notarytool store-credentials $NOTARY_PROFILE \\
        --apple-id "<your-apple-id-email>" --team-id $TEAM_ID \\
        --password <app-specific-password>
  (create the app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords)

Then re-run: ./scripts/release.sh
EOF
  exit 0
fi

echo "▸ Notarizing the app…"
ZIP="$OUT/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
rm -f "$ZIP"
echo "▸ Stapling the app…"
xcrun stapler staple "$APP"

echo "▸ Building + notarizing the DMG…"
make_dmg
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"

# ---- 4. final Gatekeeper check ----
echo "▸ Verifying Gatekeeper acceptance…"
spctl -a -vvv -t install "$DMG" 2>&1 | head -3 || true
xcrun stapler validate "$DMG" && echo "  ✓ Notarized + stapled"
echo "✅ Done: $DMG"

# ---- 5. Sparkle appcast (auto-update) --------------------------------------
# The signed DMG now needs an EdDSA-signed appcast entry so existing installs can update to it.
# That signing needs the private update key (owner's login keychain), so it is NOT done here by
# default. Opt in with SIDEWIRE_APPCAST=1 (on a machine that has the key); otherwise we just
# print the one command to run. See scripts/generate-appcast.sh + docs/08.
echo
echo "▸ Sparkle auto-update — generate + sign the appcast entry:"
if [ "${SIDEWIRE_APPCAST:-0}" = "1" ]; then
  "$ROOT/scripts/generate-appcast.sh" "$OUT"
else
  cat <<EOF
    ./scripts/generate-appcast.sh          # signs $DMG → $OUT/appcast.xml (needs your EdDSA key)
  Then upload appcast.xml + the DMG to a GitHub Release (the SUFeedURL points at
  releases/latest/download/appcast.xml). Sparkle is the app's only phone-home — see docs/08.
EOF
fi
