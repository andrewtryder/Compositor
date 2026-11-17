#!/bin/bash
# Copies the Milestone 10.4 before/after pictures next to their report.
#
# `CameraRawHorizonEvidenceTests` renders them through the real Camera Raw pipeline, but the test host is
# sandboxed and cannot write into the checkout, so it leaves them in a temporary folder. Run this after that
# test to put them where `M10_4_VIEWPOINT_GEOMETRY_INTEGRATION.md` points:
#
#   xcodebuild test -project Compositor.xcodeproj -scheme Compositor -testPlan CompositorRegression \
#     -destination 'platform=macOS' -configuration Debug \
#     -only-testing:CompositorTests/CameraRawHorizonEvidenceTests
#   scripts/horizon-evidence.sh
#
# The photographs are untracked, so a checkout without them renders nothing and this copies nothing.
set -uo pipefail

SOURCE="${1:-}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/work/geometry-validation/reports/m10_4-evidence"

# The test host is the sandboxed app, so its temporary folder is inside the app's container rather than $TMPDIR.
if [[ -z "$SOURCE" ]]; then
  for candidate in \
    "$HOME/Library/Containers/com.wonderassembly.compositor/Data/tmp/CompositorM10_4Evidence" \
    "${TMPDIR:-/tmp}/CompositorM10_4Evidence" \
    "/tmp/CompositorM10_4Evidence"; do
    if [[ -d "$candidate" ]]; then SOURCE="$candidate"; break; fi
  done
fi

if [[ -z "${SOURCE:-}" || ! -d "$SOURCE" ]]; then
  echo "No evidence folder found — run CameraRawHorizonEvidenceTests first." >&2
  exit 1
fi

count=$(find "$SOURCE" -name '*.png' | wc -l | tr -d ' ')
if [[ "$count" == 0 ]]; then
  echo "No pictures in $SOURCE — the photographs may be missing from this checkout." >&2
  exit 1
fi

mkdir -p "$DEST" || exit 1
cp "$SOURCE"/*.png "$DEST"/ || exit 1
echo "Copied $count pictures into $DEST:"
ls -1 "$DEST"
