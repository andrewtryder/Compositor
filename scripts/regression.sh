#!/bin/bash
# Runs the ordinary CompositorTests regression with an auditable test inventory.
#
# The heavy tests (the 6000×4000 Mesh Warp benchmark and the full-resolution Ricoh DNG
# end-to-end run) are excluded by the checked-in CompositorRegression test plan, not by
# comments or naming. They stay runnable through CompositorHeavy or with -only-testing.
#
# The same skip list is also passed as -skip-testing so `-enumerate-tests` reports the
# effective selection: xcodebuild enumerates every discovered test and ignores the plan's
# SkipTestIdentifiers when listing, so the plan alone cannot be audited before a run.
# The plan remains the single source of truth; the response file is generated from it.
#
# Usage:
#   scripts/regression.sh [result bundle path] [DerivedData path]
#
# Omitting the DerivedData path reuses Xcode's default one for this project, which keeps
# the incremental build incremental. Pass a path only for an isolated run.
#
# Env:
#   SKIP_BUILD=1   reuse the existing build-for-testing products
#
# Exit status is xcodebuild's own, so a failed or interrupted run is never reported green.

set -uo pipefail

RESULT="${1:-Regression-$(date +%Y.%m.%d_%H-%M-%S).xcresult}"
DERIVED="${2:-}"
PLAN="CompositorTests/CompositorRegression.xctestplan"
BUILD_LOG="regression-build.log"
TEST_LOG="regression-test.log"
# xcodebuild refuses to write enumeration output onto an existing file, so this path
# must not exist yet; the temp directory around it is removed on exit.
ENUM_DIR="$(mktemp -d -t regression-enumeration)"
ENUM="$ENUM_DIR/enumeration.txt"
SKIPS="$(mktemp -t regression-skips)"
trap 'rm -rf "$ENUM_DIR"; rm -f "$SKIPS"' EXIT

cd "$(dirname "$0")/.." || exit 1

data_args=()
[[ -n "$DERIVED" ]] && data_args=(-derivedDataPath "$DERIVED")
# macOS bash 3.2 counts an empty array as unbound under `set -u`; the "${x[@]+...}"
# form expands to nothing when empty and is the portable way to pass it through.

# The plan is the source of truth for what the ordinary regression leaves out.
python3 - "$PLAN" > "$SKIPS" <<'PY' || exit 1
import json, sys
plan = json.load(open(sys.argv[1]))
target = plan["testTargets"][0]
for name in sorted(target.get("skippedTests", [])):
    print(f"CompositorTests/{name}")
PY
[[ -s "$SKIPS" ]] || { echo "No skipped tests read from $PLAN." >&2; exit 1; }

echo "== Preflight =="
# One run at a time: a second test host on the same DerivedData fights the first for
# the GPU and the results database, which is what made the 2026-11-13 run unusable.
if pgrep -f "xcodebuild.*test" > /dev/null; then
  echo "Another xcodebuild test is running; not starting a duplicate." >&2
  pgrep -fl "xcodebuild.*test" >&2
  exit 1
fi
# A test-run app orphaned by a killed run still holds GPU buffers and its package lock.
# (macOS Accessibility and Screen Recording are granted, so the host can sit in the run loop.)
if pgrep -f "Build/Products/Debug/Compositor.app/Contents/MacOS/Compositor" > /dev/null; then
  echo "A Compositor test-run app is still running; reusing DerivedData is unsafe." >&2
  pgrep -fl "Build/Products/Debug/Compositor.app/Contents/MacOS/Compositor" >&2
  exit 1
fi
echo "load: $(uptime | sed 's/.*load averages*: //')"
echo "disk: $(df -h . | tail -1 | awk '{print $4" free"}')"
echo "swap: $(sysctl -n vm.swapusage)"

if [[ -e "$RESULT" ]]; then
  echo "Result bundle $RESULT already exists; choose a fresh path." >&2
  exit 1
fi

skip_args=()
while IFS= read -r id; do skip_args+=("-skip-testing:$id"); done < "$SKIPS"

# The inventory comes from the same selection the runner uses, so the two cannot drift.
echo "== Enumerating the selected tests =="
xcodebuild -project Compositor.xcodeproj -scheme Compositor -testPlan CompositorRegression \
  -destination 'platform=macOS' -enumerate-tests -test-enumeration-style flat \
  -test-enumeration-format text -test-enumeration-output-path "$ENUM" \
  ${data_args[@]+"${data_args[@]}"} "${skip_args[@]}" test > "$BUILD_LOG" 2>&1
enum_status=$?
if [[ "$enum_status" -ne 0 ]]; then
  echo "Enumeration failed (status $enum_status); see $BUILD_LOG" >&2
  tail -40 "$BUILD_LOG" >&2
  exit "$enum_status"
fi
discovered=$(grep -cE '^[[:space:]]+CompositorTests/' "$ENUM" || true)
selected=$(grep -E '^[[:space:]]+CompositorTests/' "$ENUM" | grep -vc '(disabled)' || true)
echo "discovered: $discovered   selected: $selected"
echo "excluded by $PLAN:"
sed 's/^/  /' "$SKIPS"

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  echo "== Incremental build-for-testing =="
  xcodebuild build-for-testing -project Compositor.xcodeproj -scheme Compositor \
    -testPlan CompositorRegression -destination 'platform=macOS' -configuration Debug \
    ${data_args[@]+"${data_args[@]}"} >> "$BUILD_LOG" 2>&1
  build_status=$?
  echo "build status: $build_status"
  if [[ "$build_status" -ne 0 ]]; then tail -40 "$BUILD_LOG" >&2; exit "$build_status"; fi
fi

echo "== Regression =="
# -parallel-testing-enabled NO: nearly every suite is @MainActor, so parallel workers only
# time-share the one main thread while competing for the GPU. See the M9.1.6 section of
# work/geometry-validation/reports/MILESTONE_9_1_2_REPOSITORY_CONSOLIDATION.md.
xcodebuild test-without-building -project Compositor.xcodeproj -scheme Compositor \
  -testPlan CompositorRegression -destination 'platform=macOS' -configuration Debug \
  ${data_args[@]+"${data_args[@]}"} -resultBundlePath "$RESULT" \
  "${skip_args[@]}" -parallel-testing-enabled NO > "$TEST_LOG" 2>&1
test_status=$?

echo "== Test results =="
xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("summary unavailable"); raise SystemExit(0)
for k in ("result", "totalTestCount", "passedTests", "failedTests", "skippedTests",
          "expectedFailures", "startTime", "finishTime"):
    if k in d:
        print(f"{k}: {d[k]}")
' 2>/dev/null || echo "summary unavailable (see $TEST_LOG)"

echo "== Excluded from this plan =="
sed 's/^/  /' "$SKIPS"

echo
echo "xcodebuild exit status: $test_status"
echo "log: $TEST_LOG"
echo "result bundle: $RESULT"
exit "$test_status"
