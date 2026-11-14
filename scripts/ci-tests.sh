#!/bin/bash
# Runs the unit tests in CI after `build-for-testing`, in several app processes at once.
#
# Nearly every suite runs on the main actor, so within one process they take turns however parallel testing is set.
# Each process has its own main thread: the suites are split between them, and the window suites, which need a
# quiet machine, run by themselves in a process of their own. New suites land in "rest" without being listed here.
#
# The filter suites run only when FILTERS=true (the workflow decides, from what changed).
#   scripts/ci-tests.sh <DerivedData path>
set -uo pipefail

DERIVED="${1:-DerivedData}"
# The regression plan's .xctestrun, by name.
#
# Not `ls ... | head -1`: `build-for-testing` writes one .xctestrun per test plan, and alphabetically
# "CompositorHeavy" sorts before "CompositorRegression". The Heavy file carries OnlyTestIdentifiers naming its two
# benchmarks, and `-only-testing` overrides that but `-skip-testing` does not — so the "rest" group below, which
# selects by skipping, matched nothing and ran 0 of its 809 tests while reporting success. Selecting the file by
# name is the fix; the plan's own SkipTestIdentifiers then keep the two benchmarks out.
XCTESTRUN=$(ls "$DERIVED"/Build/Products/*CompositorRegression*.xctestrun 2>/dev/null | head -1)
if [[ -z "$XCTESTRUN" ]]; then
  echo "No CompositorRegression .xctestrun in $DERIVED — run build-for-testing first." >&2
  echo "Found instead:" >&2
  ls "$DERIVED"/Build/Products/*.xctestrun 2>/dev/null >&2
  exit 1
fi
echo "Test plan: $(basename "$XCTESTRUN")"

FILTER_SUITES=(CameraRawTests CameraRawSliderTests HueSaturationTests ImageAdjustmentTests LevelsTests FilterTests
  ScanlinesTests FinishingFilterTests)
WINDOW_SUITES=(FloatingPanelTests SliderSnapTests)
# About half of the rest, alternating down the suites by size so neither half gets all the big ones.
FIRST_SUITES=(PSDRoundTripTests LayerTests SelectionTests SelectionEditTests TransformTests TiledLayerTests
  AdjustmentLayerTests GuideTests SelectionClipboardTests ImageImportTests CompositorTests ExternalChangeTests
  HistoryTests GradientTests CropToCanvasImportTests MaskTransformTests LiveMaskTests MaskAloneTests
  BrushIntersectionTests ShapeToolTests CanvasEntryTests PSBImportTests SmartEditTests CommandPaletteTests
  CanvasRotationTests CanvasThumbnailTests ProjectTabLayoutTests ResizeSnapTests SpotHealingTests
  PSDAdjustmentTests NewCanvasUnitTests SelectionFeatherTests BlurBrushTests)

# macOS's bash is 3.2: no mapfile, so the arguments are gathered in `args`.
only() { args=(); for suite; do args+=("-only-testing:CompositorTests/$suite"); done; }
skip() { args=(); for suite; do args+=("-skip-testing:CompositorTests/$suite"); done; }

names=() pids=()
run() {
  local name=$1; shift
  rm -rf "$name.xcresult"
  ( start=$SECONDS
    xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS,arch=arm64' \
      -resultBundlePath "$name.xcresult" "$@" > "$name.log" 2>&1
    status=$?
    echo "$((SECONDS - start))" > "$name.seconds"
    exit $status ) &
  names+=("$name") pids+=($!)
}

only "${FIRST_SUITES[@]}"; run first -parallel-testing-enabled YES "${args[@]}"
skip "${FIRST_SUITES[@]}" "${FILTER_SUITES[@]}" "${WINDOW_SUITES[@]}"; run rest -parallel-testing-enabled YES "${args[@]}"
only "${WINDOW_SUITES[@]}"; run windows -parallel-testing-enabled NO "${args[@]}"
if [[ "${FILTERS:-true}" == true ]]; then
  only "${FILTER_SUITES[@]}"; run filters -parallel-testing-enabled YES "${args[@]}"
else
  echo "Filter suites skipped: nothing they cover changed."
fi

# `rest` is the one group that selects by skipping, so it is also the one that silently matched nothing when the
# wrong .xctestrun was picked up (see the file's header and the M10.4 report). A zero here means the selection is
# broken, not that the suite is small: fail the run rather than report a green build that tested nothing of it.
failed=0
if [[ -f rest.seconds ]]; then
  rest_count=$(xcrun xcresulttool get test-results summary --path rest.xcresult 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("totalTestCount", 0))
except Exception: print(0)' 2>/dev/null || echo 0)
  echo "rest group ran $rest_count tests"
  if [[ "${rest_count:-0}" == 0 ]]; then
    echo "::error::The rest group ran no tests — the .xctestrun selection or the -skip-testing list is wrong."
    failed=1
  fi
fi

for i in "${!names[@]}"; do
  name=${names[$i]}
  if wait "${pids[$i]}"; then result=passed; else result=FAILED; failed=1; fi
  echo "::group::$name — $result in $(cat "$name.seconds" 2>/dev/null)s"
  # Slowest suites, to keep the split even.
  xcrun xcresulttool get test-results tests --path "$name.xcresult" 2>/dev/null | python3 -c '
import json, sys
suites = {}
def walk(node, suite=None):
    if node.get("nodeType") == "Test Suite": suite = node["name"]
    if node.get("nodeType") == "Test Case" and suite: suites[suite] = suites.get(suite, 0) + node.get("durationInSeconds", 0)
    for child in node.get("children", []): walk(child, suite)
for node in json.load(sys.stdin).get("testNodes", []): walk(node)
for suite, seconds in sorted(suites.items(), key=lambda s: -s[1])[:10]: print(f"{seconds:7.1f}s  {suite}")
' || true
  if [[ $result == FAILED ]]; then cat "$name.log"; else grep -E "^(Test run|\*\* TEST)" "$name.log" | tail -2; fi
  echo "::endgroup::"
  [[ $result == FAILED ]] && echo "::error::$name failed — open its group above for the log."
done
exit $failed
