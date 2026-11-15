#!/bin/bash
# Runs the unit tests in CI after `build-for-testing`, in several app processes at once.
#
# Nearly every suite runs on the main actor, so within one process they take turns however parallel testing is set.
# Each process has its own main thread: the suites are split between them, and the ones that compare rendered
# pixels or show real panels run by themselves, after the others, in a process of their own. New suites land in
# "rest" without being listed here.
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
# Suites that need a quiet machine rather than a share of one.
#   - The window suites show real panels and need the display pass to itself.
#   - `TiledLayerTests` compares a tiled draw against the same pixels drawn as one image and allows two levels of
#     difference. That is a pixel-exactness assertion: Core Graphics picks different resampling paths for the two
#     draws when the process is competing for cores, so the suite failed intermittently in the parallel groups and
#     never when run alone (M10.4, re-confirmed in M10.5: 546 pixels along one seam, off by up to 15). It runs here
#     with parallel testing off, in its own process, rather than the tolerance being widened to hide it.
QUIET_SUITES=(FloatingPanelTests SliderSnapTests TiledLayerTests)
# About half of the rest, alternating down the suites by size so neither half gets all the big ones.
FIRST_SUITES=(PSDRoundTripTests LayerTests SelectionTests SelectionEditTests TransformTests
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

# One group's report: its result, the slowest suites, and its log when it failed.
report() {
  local name=$1 result=$2
  echo "::group::$name — $result in $(cat "$name.seconds" 2>/dev/null)s"
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
}

only "${FIRST_SUITES[@]}"; run first -parallel-testing-enabled YES "${args[@]}"
skip "${FIRST_SUITES[@]}" "${FILTER_SUITES[@]}" "${QUIET_SUITES[@]}"; run rest -parallel-testing-enabled YES "${args[@]}"
if [[ "${FILTERS:-true}" == true ]]; then
  only "${FILTER_SUITES[@]}"; run filters -parallel-testing-enabled YES "${args[@]}"
else
  echo "Filter suites skipped: nothing they cover changed."
fi

# Every group is started; wait for all of them before counting. Reading a group's count while its `xcodebuild` is
# still running finds an unfinalised or absent `.xcresult` and reports zero — which is how M10.4's `rest` count
# check managed to look at a bundle that did not exist yet. Process completion and bundle finalisation come first.
failed=0
for i in "${!names[@]}"; do
  if wait "${pids[$i]}"; then result=passed; else result=FAILED; failed=1; fi
  report "${names[$i]}" "$result"
done

# The quiet suites run last, alone and with parallel testing off: they compare rendered pixels against a reference
# and need the machine to themselves. Started here rather than alongside the groups above, so nothing competes.
only "${QUIET_SUITES[@]}"
run quiet -parallel-testing-enabled NO "${args[@]}"
quiet_pid=${pids[${#pids[@]} - 1]}
if wait "$quiet_pid"; then result=passed; else result=FAILED; failed=1; fi
report quiet "$result"

# Counts, now that every `.xcresult` is finalised. `rest` is the one group that selects by skipping, so it is also
# the one that silently matched nothing when the wrong .xctestrun was picked up (see this file's header and the
# M10.4 report). A zero there means the selection is broken, not that the suite is small: fail the run rather than
# report a green build that tested nothing of it. The same check applies to every group, including the ones added
# later: a group that executes no tests is a broken selection, not a small suite.
counts=()
for name in "${names[@]}"; do
  summary=$(xcrun xcresulttool get test-results summary --path "$name.xcresult" 2>/dev/null || echo '{}')
  read -r count skipped failed_count < <(printf '%s' "$summary" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("totalTestCount", 0), d.get("skippedTests", 0), d.get("failedTests", 0))
except Exception:
    print(0, 0, 0)' 2>/dev/null || echo "0 0 0")
  counts+=("$name=${count:-0}")
  echo "$name group ran ${count:-0} tests (${skipped:-0} skipped, ${failed_count:-0} failed)"
  if [[ "${count:-0}" -eq 0 ]]; then
    echo "::error::$name ran no tests — the .xctestrun selection or its filter list is wrong."
    failed=1
  fi
  if [[ "${failed_count:-0}" -ne 0 ]]; then
    echo "::error::$name reports ${failed_count} failed tests."
    failed=1
  fi
done
echo "Test counts: ${counts[*]}"
exit $failed
