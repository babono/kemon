#!/bin/bash
#
# build-dmg.sh — package Melodash.app into a styled install DMG.
#
# Usage: scripts/build-dmg.sh <path/to/Melodash.app> <output.dmg>
#
# Why Finder/AppleScript rather than a library that writes .DS_Store directly:
# dmgbuild writes a legacy `backgroundImageAlias` record, and current macOS
# Finder ignores it — the window came up with correct icon sizes and positions
# but no background art at all. Driving Finder means Finder writes whatever
# reference format the running OS actually reads.
#
# Trade-off: this needs a GUI login session, and the first run raises a
# one-time "Terminal wants to control Finder" prompt in System Settings →
# Privacy & Security → Automation. Denying it leaves a working but unstyled
# DMG, which this script reports rather than failing silently.
#
set -euo pipefail

APP="${1:?usage: build-dmg.sh <app> <output.dmg>}"
DMG_OUT="${2:?usage: build-dmg.sh <app> <output.dmg>}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOLNAME="Melodash"
APP_BASENAME="$(basename "$APP")"
BACKGROUND="$PROJECT_ROOT/scripts/dmg-assets/background.tiff"

# Window geometry. Must match scripts/make-dmg-background.swift, which draws
# the caption and the arrow these icons sit between.
WIN_LEFT=200
WIN_TOP=180
WIN_WIDTH=660
WIN_HEIGHT=420
ICON_SIZE=128
APP_ICON_X=175
APP_ICON_Y=250
APPS_ICON_X=485
APPS_ICON_Y=250

die() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

[ -d "$APP" ] || die "No app at $APP"
[ -f "$BACKGROUND" ] || die "Missing $BACKGROUND — regenerate with: swift scripts/make-dmg-background.swift"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW_DMG="$WORK/rw.dmg"
trap 'rm -rf "$WORK"' EXIT

# --- stage contents ----------------------------------------------------------

mkdir -p "$STAGE/.background"
# ditto, not cp -R: preserves the signed bundle's extended attributes and
# symlinks exactly, so the copy stays validly signed.
ditto "$APP" "$STAGE/$APP_BASENAME"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

# Read-write, HFS+, with headroom: Finder needs to write .DS_Store into it.
SIZE_MB=$(( $(du -sm "$STAGE" | awk '{print $1}') + 60 ))

rm -f "$RW_DMG"
hdiutil create \
  -srcfolder "$STAGE" \
  -volname "$VOLNAME" \
  -fs HFS+ \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "$RW_DMG" >/dev/null

# --- style the window --------------------------------------------------------

# A stale mount of the same volume name would make Finder target the wrong disk.
hdiutil detach "/Volumes/$VOLNAME" -force -quiet 2>/dev/null || true

MOUNT_OUTPUT="$(hdiutil attach "$RW_DMG" -noautoopen -nobrowse)"
MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | sed -n '1p')"
[ -n "$MOUNT_POINT" ] || die "Could not determine mount point"

cleanup_mount() {
  hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup_mount EXIT

STYLED=1
osascript <<EOF || STYLED=0
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {$WIN_LEFT, $WIN_TOP, $((WIN_LEFT + WIN_WIDTH)), $((WIN_TOP + WIN_HEIGHT))}

    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set shows icon preview of opts to false
    -- HFS-style path, relative to the volume root.
    set background picture of opts to file ".background:background.tiff"

    set position of item "$APP_BASENAME" of container window to {$APP_ICON_X, $APP_ICON_Y}
    set position of item "Applications" of container window to {$APPS_ICON_X, $APPS_ICON_Y}

    -- Force the view settings out to .DS_Store before the volume is detached.
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

if [ "$STYLED" -eq 0 ]; then
  printf '\n\033[1;33mWarning:\033[0m Finder styling failed — the DMG will work but look unstyled.\n' >&2
  printf '  Grant Automation access for Finder: System Settings → Privacy & Security → Automation.\n' >&2
fi

# Let Finder finish flushing .DS_Store before the volume goes away.
sync
sleep 1

hdiutil detach "$MOUNT_POINT" -force -quiet
trap 'rm -rf "$WORK"' EXIT

# --- compress ----------------------------------------------------------------

rm -f "$DMG_OUT"
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_OUT" >/dev/null

[ -f "$DMG_OUT" ] || die "Conversion produced no DMG at $DMG_OUT"
echo "Built $DMG_OUT"
