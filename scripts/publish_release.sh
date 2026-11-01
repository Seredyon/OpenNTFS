#!/bin/bash
# Runs only after successful tag builds. Existing public releases are never overwritten.
set -euo pipefail
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
VERSION="$(cat VERSION)"
[ "$RELEASE_TAG" = "v$VERSION" ] || { echo 'Release tag does not match VERSION.'; exit 1; }
ASSET="OpenNTFS-$VERSION-arm64.dmg"
(cd dist && sha256sum -c "$ASSET.sha256")
if gh release view "$RELEASE_TAG" --json isDraft > dist/release-state.json 2>/dev/null; then
  python3 - <<'PY'
import json
if not json.load(open('dist/release-state.json'))['isDraft']:
    raise SystemExit('This release is already public. Publish a new version instead.')
PY
else
  gh release create "$RELEASE_TAG" --verify-tag --draft --title "OpenNTFS $VERSION" --notes-file .github/RELEASE_NOTES.md
fi
gh release upload "$RELEASE_TAG" "dist/$ASSET" "dist/$ASSET.sha256" --clobber
gh release edit "$RELEASE_TAG" --draft=false
