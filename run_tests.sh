#!/bin/bash
# Runs the automated test suite against a built app. Only disposable image files under
# <build>/test-images are written; physical drives are never modified.
# Usage: ./run_tests.sh [--quick]   (--quick skips the >4 GiB large-file test)
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
export OPENNTFS_BUILD="${OUTPUT_DIR:-${OPENNTFS_BUILD:-$SOURCE_DIR/build}}"
mkdir -p "$OPENNTFS_BUILD/validation"; OPENNTFS_BUILD="$(cd "$OPENNTFS_BUILD" && pwd)"
export OPENNTFS_APP="${OPENNTFS_APP:-$OPENNTFS_BUILD/OpenNTFS.app}"
export TMPDIR="$OPENNTFS_BUILD/.cache/tmp/" CLANG_MODULE_CACHE_PATH="$OPENNTFS_BUILD/.cache/clang" PYTHONDONTWRITEBYTECODE=1
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
[ -x "$OPENNTFS_APP/Contents/MacOS/NTFSWorker" ] || { echo "Build the app first: ./build.sh"; exit 1; }
case "${1:-}" in ""|--quick) ;; *) echo "Usage: ./run_tests.sh [--quick]"; exit 2 ;; esac
[ "$#" -le 1 ] || { echo "Usage: ./run_tests.sh [--quick]"; exit 2; }
export XDG_CACHE_HOME="$OPENNTFS_BUILD/.cache"
tests=(test_worker test_edges test_volume_flags test_target_state test_progress_cancel test_mixed_case test_batch test_check)
[ "${1:-}" = "--quick" ] || tests+=(test_large_file)
failed=0
for t in "${tests[@]}"; do
  printf '%-22s ' "$t"
  if python3 "$SOURCE_DIR/tests/$t.py" > "$OPENNTFS_BUILD/validation/$t.log" 2>&1; then echo PASS; else echo "FAIL (see build/validation/$t.log)"; failed=1; fi
done
printf '%-22s ' "security_inherit"
if xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
     "$SOURCE_DIR/Sources/NTFS/"*.swift "$SOURCE_DIR/tests/SecurityInheritTests.swift" -o "$OPENNTFS_BUILD/.cache/security_inherit" \
   && "$OPENNTFS_BUILD/.cache/security_inherit" | tail -1 | grep -q OK; then echo PASS; else echo FAIL; failed=1; fi
# The NTFS implementation on its own, through its command-line tool. test_write and test_reference
# need a separate NTFS implementation (OPENNTFS_REFERENCE_WORKER) and skip without one.
NTFS_TOOL="$OPENNTFS_BUILD/.cache/ntfs-tool"
printf '%-22s ' "ntfs_tool"
if xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
     "$SOURCE_DIR/Sources/NTFS/"*.swift "$SOURCE_DIR/Sources/NTFSTool/Main.swift" -o "$NTFS_TOOL"; then echo PASS; else echo FAIL; failed=1; fi
for t in test_native test_compressed test_native_check test_write test_reference; do
  printf '%-22s ' "$t"
  if python3 "$SOURCE_DIR/tests/ntfs/$t.py" "$NTFS_TOOL" "$OPENNTFS_BUILD/test-images/ntfs" > "$OPENNTFS_BUILD/validation/$t.log" 2>&1; then echo PASS; else echo "FAIL (see build/validation/$t.log)"; failed=1; fi
done
exit $failed
