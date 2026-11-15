#!/bin/bash
# Copies the Milestone 10.5 corrected-beside-source pictures next to their report.
#
# `CameraRawPerspectiveEvidenceTests` renders them through the real Camera Raw pipeline, but the test host is
# sandboxed and cannot write into the checkout, so it leaves them in a temporary folder. Run this after that
# test to put them where `M10_5_ADVANCED_PERSPECTIVE_TOOLS.md` points:
#
#   xcodebuild test -project Compositor.xcodeproj -scheme Compositor -testPlan CompositorRegression \
#     -destination 'platform=macOS' -configuration Debug \
#     -only-testing:CompositorTests/CameraRawPerspectiveEvidenceTests
#   scripts/perspective-evidence.sh
#
# The photographs are untracked, so a checkout without them renders nothing and this copies nothing.
set -uo pipefail

SOURCE="${1:-}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/work/camera-raw-parity/screenshots/m10_5-rendered"

# The test host is the sandboxed app, so its temporary folder is inside the app's container rather than $TMPDIR.
if [[ -z "$SOURCE" ]]; then
  for candidate in \
    "$HOME/Library/Containers/com.wonderassembly.compositor/Data/tmp/CompositorM10_5Evidence" \
    "${TMPDIR:-/tmp}/CompositorM10_5Evidence" \
    "/tmp/CompositorM10_5Evidence"; do
    if [[ -d "$candidate" ]]; then SOURCE="$candidate"; break; fi
  done
fi

if [[ -z "${SOURCE:-}" || ! -d "$SOURCE" ]]; then
  echo "No evidence folder found — run CameraRawPerspectiveEvidenceTests first." >&2
  exit 1
fi

count=$(find "$SOURCE" \( -name '*.png' -o -name '*.csv' \) | wc -l | tr -d ' ')
if [[ "$count" == 0 ]]; then
  echo "No pictures in $SOURCE — the photographs may be missing from this checkout." >&2
  exit 1
fi

mkdir -p "$DEST" || exit 1
cp "$SOURCE"/*.png "$DEST"/ 2>/dev/null || true
cp "$SOURCE"/*.csv "$DEST"/ 2>/dev/null || true
echo "Copied $(find "$DEST" -type f | wc -l | tr -d ' ') files into $DEST:"
ls -1 "$DEST"
