#!/usr/bin/env bash
#
# Builds the app and runs its tests on an iOS Simulator — the same steps CI runs.
#
#   scripts/test.sh          unit tests + UI tests
#   scripts/test.sh unit     unit tests only (fast)
#   scripts/test.sh ui       UI tests only
#
# Results go to build/*.xcresult; open one in Xcode to see failures and coverage.
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Midi Set List.xcodeproj"
SCHEME="Midi Set List"
WHICH="${1:-all}"
DERIVED="build/DerivedData"

# Newest iOS runtime's first iPhone, unless SIMULATOR_ID is set
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
for runtime in sorted(devices, key=version, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No iPhone simulator found. Install an iOS runtime in Xcode › Settings › Components.")
')
fi
echo "Simulator: $SIMULATOR_ID"

COMMON=(-project "$PROJECT" -scheme "$SCHEME" -destination "id=$SIMULATOR_ID"
        -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO)

mkdir -p build

echo "▶ Building for testing"
xcodebuild build-for-testing "${COMMON[@]}" -quiet

status=0
if [[ "$WHICH" == "all" || "$WHICH" == "unit" ]]; then
  echo "▶ Unit tests"
  rm -rf build/UnitTests.xcresult
  xcodebuild test-without-building "${COMMON[@]}" \
    -only-testing:"Midi Set ListTests" \
    -resultBundlePath build/UnitTests.xcresult || status=1
fi

if [[ "$WHICH" == "all" || "$WHICH" == "ui" ]]; then
  echo "▶ UI tests"
  rm -rf build/UITests.xcresult
  # The launch-time benchmark and per-appearance screenshots are for local runs
  xcodebuild test-without-building "${COMMON[@]}" \
    -only-testing:"Midi Set ListUITests/Midi_Set_ListUITests" \
    -skip-testing:"Midi Set ListUITests/Midi_Set_ListUITests/testLaunchPerformance" \
    -resultBundlePath build/UITests.xcresult || status=1
fi

exit $status
