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
tests=(test_worker test_edges test_volume_flags test_target_state test_progress_cancel test_mixed_case test_batch)
[ "${1:-}" = "--quick" ] || tests+=(test_large_file)
failed=0
for t in "${tests[@]}"; do
  printf '%-22s ' "$t"
  if python3 "$SOURCE_DIR/tests/$t.py" > "$OPENNTFS_BUILD/validation/$t.log" 2>&1; then echo PASS; else echo "FAIL (see build/validation/$t.log)"; failed=1; fi
done
printf '%-22s ' "sec_inherit_test"
if xcrun clang++ -std=c++17 -fobjc-arc -O1 -arch arm64 -mmacosx-version-min=13.0 -fmodules-cache-path="$CLANG_MODULE_CACHE_PATH" -Wno-unused-function -I"$OPENNTFS_BUILD/generated" \
     "$SOURCE_DIR/tests/sec_inherit_test.mm" -framework Foundation -framework IOKit -o "$OPENNTFS_BUILD/.cache/sec_inherit_test" \
   && "$OPENNTFS_BUILD/.cache/sec_inherit_test" | tail -1 | grep -q OK; then echo PASS; else echo FAIL; failed=1; fi
exit $failed
