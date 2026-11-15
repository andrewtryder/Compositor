#!/bin/bash
# Copies the Milestone 10.6 calibrated-correction evidence next to its report.
#
# `CameraRawLensfunEvidenceTests` renders them through the real Camera Raw pipeline, but the test host is
# sandboxed and cannot write into the checkout, so it leaves them in a temporary folder. Run this after that
# test to put them where `M10_6_CALIBRATED_LENSFUN_CORRECTIONS.md` points:
#
#   xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
#     -configuration Debug -only-testing:CompositorTests/CameraRawLensfunEvidenceTests
#   scripts/lensfun-evidence.sh
#
# The photographs and the imported Lensfun XML under originals/lensfun-evidence-db are untracked, so a
# checkout without them renders nothing and this copies nothing.
set -uo pipefail

SOURCE="${1:-}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/work/camera-raw-parity/screenshots/m10_6-rendered"

# The test host is the sandboxed app, so its temporary folder is inside the app's container rather than $TMPDIR.
if [[ -z "$SOURCE" ]]; then
  for candidate in \
    "$HOME/Library/Containers/com.wonderassembly.compositor/Data/tmp/CompositorM10_6Evidence" \
    "${TMPDIR:-/tmp}/CompositorM10_6Evidence" \
    "/tmp/CompositorM10_6Evidence"; do
    if [[ -d "$candidate" ]]; then SOURCE="$candidate"; break; fi
  done
fi

if [[ -z "${SOURCE:-}" || ! -d "$SOURCE" ]]; then
  echo "No evidence folder found — run CameraRawLensfunEvidenceTests first." >&2
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
