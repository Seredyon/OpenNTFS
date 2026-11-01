#!/bin/bash
# Create an installer without Finder automation or interactive dialogs.
set -euo pipefail
[ "$#" = 4 ] || { echo 'Usage: make_dmg.sh <app> <resources> <output.dmg> <work>'; exit 2; }
APP="$1"; RESOURCES="$2"; DMG="$3"; WORK="$4"
mkdir -p "$WORK" "$(dirname "$DMG")"
STAGE="$(mktemp -d "$WORK/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"
export COPYFILE_DISABLE=1
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/OpenNTFS.app"
ln -s /Applications "$STAGE/Applications"
cp "$RESOURCES/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
/usr/bin/xattr -wx com.apple.FinderInfo '0000000000000000040000000000000000000000000000000000000000000000' "$STAGE"
/usr/bin/hdiutil create -quiet -volname OpenNTFS -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG"
/usr/bin/hdiutil verify "$DMG" -quiet
