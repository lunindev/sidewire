#!/bin/bash
#
# Sidewire release pipeline: build → Developer ID sign (hardened runtime) → verify → DMG →
# notarize → staple. The everyday Xcode build keeps its Apple Development signing; this script
# overrides signing for distribution only, so it never disturbs the dev workflow / TCC grants.
#
# One-time setup (you, once — enters your Apple credentials, which this script never sees):
#   xcrun notarytool store-credentials sidewire-notary \
#       --apple-id "<your-apple-id-email>" --team-id <YOUR_TEAM_ID> \
#       --password <app-specific-password from appleid.apple.com → App-Specific Passwords>
#
# Then just:  ./scripts/release.sh
# Without the notary profile it still builds+signs+DMGs and tells you what to run.
set -euo pipefail

# ---- config ----------------------------------------------------------------
IDENTITY="Developer ID Application: <Your Name> (<YOUR_TEAM_ID>)"
TEAM_ID="<YOUR_TEAM_ID>"
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

echo "▸ Sidewire $VERSION → $DMG"
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
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  make_dmg
  cat <<EOF

▸ Built + signed, DMG created (NOT yet notarized):
    $DMG

To notarize, create the credentials profile once (this enters YOUR Apple password, not me):
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
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"
echo "▸ Stapling the app…"
xcrun stapler staple "$APP"

echo "▸ Building + notarizing the DMG…"
make_dmg
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
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
