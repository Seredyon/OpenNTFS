#!/bin/bash
# Create the installer: a small dark window with OpenNTFS on the left, Applications on the right
# and an arrow between them. The window layout (.DS_Store) is written by make_dsstore.py, so
# neither Finder automation nor interactive dialogs are needed (CI runners included).
set -euo pipefail
[ "$#" = 4 ] || { echo 'Usage: make_dmg.sh <app> <resources> <output.dmg> <work>'; exit 2; }
APP="$1"; RESOURCES="$2"; DMG="$3"; WORK="$4"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
VOLUME=OpenNTFS
mkdir -p "$WORK" "$(dirname "$DMG")"
STAGE="$(mktemp -d "$WORK/dmg-stage.XXXXXX")"
RW="$STAGE.rw.dmg"; MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then /usr/bin/hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true; fi
  rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT
chmod 755 "$STAGE"
export COPYFILE_DISABLE=1
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/OpenNTFS.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
# One TIFF with the 1x and 2x pictures, so Retina screens get the sharp version.
/usr/bin/tiffutil -cathidpicheck "$RESOURCES/dmg/background.png" "$RESOURCES/dmg/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
cp "$RESOURCES/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
/usr/bin/xattr -wx com.apple.FinderInfo '0000000000000000040000000000000000000000000000000000000000000000' "$STAGE"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 16 ))
/usr/bin/hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$RW"
# Mount privately inside the work folder; fall back to an unlisted mount under /Volumes.
MOUNT="$(mktemp -d "$WORK/dmg-mount.XXXXXX")"
if ! /usr/bin/hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" -quiet 2>/dev/null; then
  rmdir "$MOUNT"
  MOUNT="$(/usr/bin/hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)"
  [ -n "$MOUNT" ] || { echo 'Could not mount the installer image'; exit 1; }
fi
/usr/bin/python3 "$SCRIPTS/make_dsstore.py" "$MOUNT" "$VOLUME" OpenNTFS.app
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
/bin/sync
/usr/bin/hdiutil detach "$MOUNT" -quiet
case "$MOUNT" in "$WORK"/*) rmdir "$MOUNT" 2>/dev/null || true ;; esac
MOUNT=""
/usr/bin/hdiutil convert "$RW" -quiet -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"
/usr/bin/hdiutil verify "$DMG" -quiet
