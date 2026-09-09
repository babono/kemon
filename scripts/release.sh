#!/bin/bash
#
# release.sh — build, sign, notarize, staple and package Melodash for direct
# distribution from melodash.app.
#
# The app shipped before this script existed was signed but never notarized
# (hardened runtime was off, which notarization requires), so Gatekeeper
# rejected it on every Mac but the developer's. This script makes that state
# unreachable: it refuses to produce a DMG that `spctl` would reject.
#
# One-time setup — store an App Store Connect credential in the keychain:
#
#   xcrun notarytool store-credentials melodash \
#     --apple-id <your-apple-id> \
#     --team-id U96VKD93X4 \
#     --password <app-specific-password>
#
# App-specific passwords come from appleid.apple.com → Sign-In and Security.
#
# Usage: scripts/release.sh
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SCHEME="Melodash"
APP_NAME="Melodash"
TEAM_ID="U96VKD93X4"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-melodash}"

BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG_STAGE="$BUILD_DIR/dmg"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# Notarizing the app is the slow step — Apple can take anywhere from one to
# forty minutes. --dmg-only resumes from an already-notarized, already-stapled
# app in build/export, so a failure in the packaging half doesn't cost another
# round trip.
DMG_ONLY=0
case "${1:-}" in
  --dmg-only) DMG_ONLY=1 ;;
  "") ;;
  *) die "Unknown argument: $1 (expected --dmg-only or nothing)" ;;
esac

# --- preflight ---------------------------------------------------------------

xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
  || die "No notarytool keychain profile '$KEYCHAIN_PROFILE'. See the setup block at the top of this script."

if [ "$DMG_ONLY" -eq 1 ]; then
  [ -d "$APP" ] || die "--dmg-only needs an exported app at $APP; run without the flag."
  xcrun stapler validate "$APP" >/dev/null 2>&1 \
    || die "--dmg-only needs an already-stapled app at $APP; run without the flag."
  log "Resuming from stapled app at $APP"
fi

if [ "$DMG_ONLY" -eq 0 ]; then

# --- archive -----------------------------------------------------------------

log "Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Archiving $SCHEME for macOS"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  ENABLE_HARDENED_RUNTIME=YES \
  | grep -E 'error:|warning: .*(deprecated|will never be executed)|ARCHIVE (SUCCEEDED|FAILED)' || true

[ -d "$ARCHIVE" ] || die "Archive not produced at $ARCHIVE"

# --- export ------------------------------------------------------------------

log "Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  | grep -E 'error:|EXPORT (SUCCEEDED|FAILED)' || true

[ -d "$APP" ] || die "Export produced no app at $APP"

# Hardened runtime is what made the old builds un-notarizable. Catch a
# regression here rather than after a five-minute round trip to Apple.
#
# Captured into a variable rather than piped: under `set -o pipefail` a
# short-circuiting reader (grep -q, head -1) SIGPIPEs codesign and the whole
# pipeline reports failure even on a match.
CODESIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"

case "$CODESIGN_INFO" in
  *"flags=0x"*"runtime"*) ;;
  *) die "Hardened runtime is not enabled on the exported app — notarization would fail." ;;
esac

AUTHORITY="$(printf '%s\n' "$CODESIGN_INFO" | sed -n 's/^Authority=//p' | sed -n '1p')"
case "$AUTHORITY" in
  "Developer ID Application"*) ;;
  *) die "Expected a Developer ID Application signature, got: ${AUTHORITY:-none}" ;;
esac

log "Signed as: $AUTHORITY"

# --- notarize ----------------------------------------------------------------

# notarytool takes a zip/dmg/pkg, never a bare .app.
ZIP_FOR_NOTARY="$BUILD_DIR/$APP_NAME-notary.zip"
log "Submitting to Apple for notarization (this usually takes 1-5 minutes)"
ditto -c -k --keepParent "$APP" "$ZIP_FOR_NOTARY"

xcrun notarytool submit "$ZIP_FOR_NOTARY" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait \
  || die "Notarization failed. Run: xcrun notarytool log <submission-id> --keychain-profile $KEYCHAIN_PROFILE"

log "Stapling the notarization ticket"
xcrun stapler staple "$APP"

fi  # end DMG_ONLY guard

# --- verify ------------------------------------------------------------------

# The check the old release never passed. A stapled app must satisfy spctl
# with no network access, which is what a first-time user's Mac actually does.
log "Verifying with Gatekeeper"
spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/    /'
spctl -a -t exec "$APP" >/dev/null 2>&1 || die "spctl still rejects the app — do not ship this build."
xcrun stapler validate "$APP" >/dev/null || die "Stapled ticket did not validate."

# --- package -----------------------------------------------------------------

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

log "Building $APP_NAME-$VERSION.dmg"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
# Drag-to-install target, so the window explains itself without instructions.
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

# The DMG is signed and notarized separately from the app inside it; without
# this the download itself trips Gatekeeper even though the app is clean.
log "Signing and notarizing the DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait \
  || die "DMG notarization failed."
xcrun stapler staple "$DMG"

# --- appcast -----------------------------------------------------------------

# Sparkle checks this feed and refuses any update whose EdDSA signature does not
# verify against SUPublicEDKey in Info.plist. generate_appcast signs each
# archive in RELEASES_DIR with the private key from the login keychain, so past
# releases must stay in that directory for the feed to keep listing them.
RELEASES_DIR="$PROJECT_ROOT/releases"
# `sed -n 1p` rather than `head -1`: head exits early and SIGPIPEs find, which
# pipefail would surface as a failure of the whole substitution.
GENERATE_APPCAST="$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' -type f 2>/dev/null | sed -n '1p')"

if [ -z "$GENERATE_APPCAST" ]; then
  echo "    Warning: generate_appcast not found (resolve the Sparkle package first)."
  echo "    Skipping appcast generation; $DMG is still shippable."
else
  log "Generating appcast.xml"
  mkdir -p "$RELEASES_DIR"
  cp "$DMG" "$RELEASES_DIR/"
  "$GENERATE_APPCAST" "$RELEASES_DIR" --download-url-prefix "https://www.melodash.app/releases/"
  echo "    Wrote $RELEASES_DIR/appcast.xml"
fi

log "Done: $DMG"
cat <<EOF
    To publish:
      1. Upload $(basename "$DMG") to https://www.melodash.app/releases/
      2. Upload releases/appcast.xml to https://www.melodash.app/appcast.xml
      3. Replace the Melodash.zip download link with the DMG.
EOF
