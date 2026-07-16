#!/bin/bash
#
# Sidewire — generate + EdDSA-sign the Sparkle appcast.  *** OWNER-RUN ***
#
# This needs the EdDSA PRIVATE update key, which lives only in the owner's login keychain, so it
# is NOT run by CI (unless the key is provided as a secret — see .github/workflows/release.yml).
# A leaked update key lets an attacker ship a malicious "update", so guard it like a signing key.
#
# One-time, before the first release (you, once):
#   generate_keys                       # from the Sparkle SPM artifact's bin/ (see below)
#   → prints your PUBLIC key. Paste it into Sidewire/Resources/Info.plist under SUPublicEDKey.
#   The matching PRIVATE key is stored in your login keychain; generate_appcast reads it from there.
#
# Then, after ./scripts/release.sh has produced dist/Sidewire-<version>.dmg:
#   ./scripts/generate-appcast.sh            # signs the DMG(s) → dist/appcast.xml
#   Upload dist/appcast.xml + the DMG to the GitHub Release so the SUFeedURL resolves.
#
# The Sparkle CLI tools (generate_appcast, generate_keys, sign_update) ship inside the resolved
# Sparkle SPM artifact:
#   <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/
# (release.sh uses -derivedDataPath build/release-dd, so they land under build/release-dd/… there.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${1:-$ROOT/dist}"

# Where the DMG will be downloadable from. The appcast's <enclosure url> is this prefix + the DMG
# filename, so it MUST match the host in Info.plist's SUFeedURL. OWNER: set the real repo owner
# (export SIDEWIRE_REPO_OWNER=you) or override DOWNLOAD_URL_PREFIX outright.
OWNER="${SIDEWIRE_REPO_OWNER:-OWNER}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$OWNER/sidewire/releases/latest/download/}"

# ---- locate Sparkle's generate_appcast -------------------------------------
find_tool() {
  if [ -n "${GENERATE_APPCAST:-}" ]; then echo "$GENERATE_APPCAST"; return 0; fi
  if command -v generate_appcast >/dev/null 2>&1; then command -v generate_appcast; return 0; fi
  local candidates=()
  candidates+=("$ROOT/build/release-dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast")
  local g
  for g in "$HOME/Library/Developer/Xcode/DerivedData/"Sidewire-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast; do
    candidates+=("$g")
  done
  local c
  for c in "${candidates[@]}"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

TOOL="$(find_tool)" || {
  cat <<EOF
✗ Could not find Sparkle's generate_appcast.
  It ships in the resolved Sparkle SPM artifact:
    <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast
  Resolve packages once (xcodegen generate && xcodebuild -resolvePackageDependencies) or
  set GENERATE_APPCAST=/path/to/generate_appcast and re-run.
EOF
  exit 1
}

[ -d "$DIST" ] || { echo "✗ No dist dir: $DIST — build a DMG first: ./scripts/release.sh"; exit 1; }
ls "$DIST"/*.dmg >/dev/null 2>&1 || { echo "✗ No .dmg in $DIST — run ./scripts/release.sh first"; exit 1; }

echo "▸ generate_appcast: $TOOL"
echo "▸ Signing updates in: $DIST"
echo "▸ Download URL prefix: $DOWNLOAD_URL_PREFIX"
# A hard failure, not a warning. With the placeholder every <enclosure url> points at
# github.com/OWNER/… — Sparkle finds the update, announces it, and 404s on the download. The old
# `⚠︎` printed one line into twenty lines of success output and then wrote the broken appcast
# anyway. (release.sh exports SIDEWIRE_REPO_OWNER from the SUFeedURL it just validated, so the
# owner and the feed can't disagree; this catches a direct invocation.)
if [ "$OWNER" = "OWNER" ]; then
  echo "✗ OWNER is still the placeholder, so every download URL in the appcast would 404."
  echo "  export SIDEWIRE_REPO_OWNER=<your-github-owner>   (or set DOWNLOAD_URL_PREFIX outright)"
  exit 1
fi

# generate_appcast reads the EdDSA PRIVATE key from the login keychain (stored by generate_keys)
# and appends an sparkle:edSignature to each enclosure. Writes appcast.xml into $DIST.
"$TOOL" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$DIST"

echo "✅ appcast.xml written to $DIST/appcast.xml"
echo "   Next: upload $DIST/appcast.xml + the DMG(s) to the GitHub Release so"
echo "   ${DOWNLOAD_URL_PREFIX}appcast.xml and the DMG both resolve."
