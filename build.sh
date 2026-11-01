#!/bin/bash
# Build an Apple silicon app and a headless DMG. All output stays in OUTPUT_DIR.
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SOURCE_DIR/build}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_DIR="$OUTPUT_DIR/OpenNTFS.app"
VERSION="$(cat "$SOURCE_DIR/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MAKE_DMG=1
for argument in "$@"; do
  case "$argument" in --no-dmg) MAKE_DMG=0 ;; *) echo "Usage: ./build.sh [--no-dmg]"; exit 2 ;; esac
done
CACHE_DIR="$OUTPUT_DIR/.cache"
export TMPDIR="$CACHE_DIR/tmp/"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export XDG_CACHE_HOME="$CACHE_DIR"
export PYTHONDONTWRITEBYTECODE=1
export COPYFILE_DISABLE=1
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$OUTPUT_DIR/validation" "$OUTPUT_DIR/generated"
command -v xcrun >/dev/null || { echo "Xcode Command Line Tools are required."; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Build and test on an Apple silicon Mac."; exit 1; }
python3 - "$VERSION" "$BUILD_NUMBER" <<'PY'
import re,sys
if sys.version_info < (3,11): raise SystemExit('Python 3.11 or newer is required.')
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',sys.argv[1]):
    raise SystemExit('VERSION must contain a version such as 0.3.0.')
if not re.fullmatch(r'[1-9][0-9]*',sys.argv[2]): raise SystemExit('BUILD_NUMBER must be a positive integer.')
PY
python3 "$SOURCE_DIR/scripts/check_localization.py" "$SOURCE_DIR/Sources/App" "$SOURCE_DIR/Resources"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources/Temporary"
python3 "$SOURCE_DIR/scripts/prepare_engine.py" "$SOURCE_DIR/Engine/NTFS_util-9e3e2782" \
  "$APP_DIR/Contents/Frameworks/NTFSEngine.bundle" "$OUTPUT_DIR/validation/engine-adaptation.json"
/usr/bin/codesign --force --sign - "$APP_DIR/Contents/Frameworks/NTFSEngine.bundle"
cp -R "$SOURCE_DIR/Resources/"*.lproj "$APP_DIR/Contents/Resources/"
cp "$SOURCE_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
python3 - "$OUTPUT_DIR/generated" "$APP_DIR" "$VERSION" "$BUILD_NUMBER" <<'PY'
from pathlib import Path
import hashlib,plistlib,sys
headers,app=map(Path,sys.argv[1:3]);version,build=sys.argv[3:5]
hash_value=hashlib.sha256((app/'Contents/Frameworks/NTFSEngine.bundle').read_bytes()).hexdigest()
(headers/'EngineHash.h').write_text('#define EXPECTED_ENGINE_SHA256 "'+hash_value+'"\n')
info={
 'CFBundleExecutable':'OpenNTFS','CFBundleIdentifier':'local.openntfs.portable',
 'CFBundleName':'OpenNTFS','CFBundleDisplayName':'OpenNTFS','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':version,'CFBundleVersion':build,'CFBundleDevelopmentRegion':'en',
 'CFBundleLocalizations':['en','ru'],'CFBundleIconFile':'AppIcon',
 'LSMinimumSystemVersion':'13.0','LSArchitecturePriority':['arm64'],
 'LSApplicationCategoryType':'public.app-category.utilities','NSHighResolutionCapable':True,
 'NSRemovableVolumesUsageDescription':'OpenNTFS needs access to the selected drive to read and write NTFS.',
 'NSDisablePersistence':True,'NSQuitAlwaysKeepsWindows':False,
 'NSSupportsAutomaticTermination':False,'NSSupportsSuddenTermination':False
}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun clang++ -std=c++17 -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=13.0 \
  -I"$OUTPUT_DIR/generated" -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" \
  "$SOURCE_DIR/Sources/NTFSWorker.mm" -framework Foundation -framework IOKit \
  -o "$APP_DIR/Contents/MacOS/NTFSWorker"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" -module-name OpenNTFS \
  -framework SwiftUI -framework AppKit -framework IOKit -framework Quartz \
  -framework UniformTypeIdentifiers -framework DiskArbitration -parse-as-library \
  "$SOURCE_DIR/Sources/App/"*.swift -o "$APP_DIR/Contents/MacOS/OpenNTFS"
/usr/bin/codesign --force --sign - "$APP_DIR/Contents/MacOS/NTFSWorker"
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s (%s)\n' "$APP_DIR" "$VERSION"
if [ "$MAKE_DMG" = 1 ]; then
  DMG="$OUTPUT_DIR/OpenNTFS-$VERSION-arm64.dmg"
  /bin/bash "$SOURCE_DIR/scripts/make_dmg.sh" "$APP_DIR" "$SOURCE_DIR/Resources" "$DMG" "$CACHE_DIR"
  (cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
  printf 'Installer %s\n' "$DMG"
fi
