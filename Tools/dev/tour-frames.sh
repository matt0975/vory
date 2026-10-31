#!/bin/bash
# Onboarding's beat 5 pictures (#388): the app on the demo on the other devices, sized into the asset catalog.
#
#   Tools/dev/tour-frames.sh <derived data> <iPhone simulator> <iPad simulator> <folder> [<Watch simulator>]
#
# Runs TourFrameShotsUITests on the iPhone and the iPad (TourPhone-light/dark, TourPad-light/dark), from a
# build-for-testing in <derived data>, with the status bars at 9:41. With a Watch simulator, and the mock gateway running
# on 127.0.0.1:9119 (Tools/mock-gateway/mock_gateway.py --port 9119 --token mock-token), it also makes TourWatch.png from
# a VoryWatch build-for-testing in the same <derived data> (WatchChatUITests/testTheToursAskOnTheWatch: the mock's tour
# ask). <folder> holds the Mac's too, made by the Mac app's harness: TourMac-light.png and TourMac-dark.png.
# Every picture is then sized for where the tour shows it and written as an image set with its light and dark looks.
# Read the pictures before committing them: the demo has no gateway, so nothing real should be in them.
set -euo pipefail
DD="${1:?derived data}"; PHONE="${2:?iPhone simulator}"; PAD="${3:?iPad simulator}"; OUT="${4:?folder}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ASSETS="$ROOT/Vory/Resources/Assets.xcassets"
mkdir -p "$OUT"

for SIM in "$PHONE" "$PAD"; do
  xcrun simctl boot "$SIM" 2>/dev/null || true
  xcrun simctl bootstatus "$SIM" -b >/dev/null
  xcrun simctl status_bar "$SIM" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
  (cd "$ROOT" && env TEST_RUNNER_TOUR_FRAMES_OUT="$OUT" xcodebuild test-without-building -project Vory.xcodeproj -scheme Vory \
    -destination "id=$SIM" -derivedDataPath "$DD" -only-testing:VoryUITests/TourFrameShotsUITests \
    -parallel-testing-enabled NO -collect-test-diagnostics never | grep -E "Test Case|error:|\*\* TEST" || true)
  xcrun simctl status_bar "$SIM" clear
done

if [ -n "${5:-}" ]; then
  WATCH="$5"
  xcrun simctl boot "$WATCH" 2>/dev/null || true
  xcrun simctl bootstatus "$WATCH" -b >/dev/null
  (cd "$ROOT" && env TEST_RUNNER_TOUR_FRAMES_OUT="$OUT" TEST_RUNNER_HERMES_E2E_URL="http://127.0.0.1:9119" TEST_RUNNER_HERMES_E2E_TOKEN=mock-token \
    xcodebuild test-without-building -project Vory.xcodeproj -scheme VoryWatch -destination "id=$WATCH" -derivedDataPath "$DD" \
    -only-testing:VoryWatchUITests/WatchChatUITests/testTheToursAskOnTheWatch -parallel-testing-enabled NO \
    -collect-test-diagnostics never | grep -E "Test Case|error:|\*\* TEST" || true)
fi

# name, width in pixels (about three times the points the tour gives it), looks
write() {
  local name="$1" width="$2" looks="$3" set="$ASSETS/$1.imageset" images=""
  for look in $looks; do
    local src="$OUT/$name-$look.png"; [ "$look" = any ] && src="$OUT/$name.png"
    [ -f "$src" ] || { echo "$name: no $src, left as it was"; MISSING=1; return 0; }
  done
  mkdir -p "$set"
  for look in $looks; do
    local src="$OUT/$name-$look.png" file="$name-$look.jpg"
    [ "$look" = any ] && src="$OUT/$name.png" && file="$name.jpg"
    sips -s format jpeg -s formatOptions 82 --resampleWidth "$width" "$src" --out "$set/$file" >/dev/null
    local appearance=""
    [ "$look" = dark ] && appearance=', "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ]'
    images="$images${images:+,
}    { \"filename\" : \"$file\", \"idiom\" : \"universal\"$appearance }"
  done
  printf '{\n  "images" : [\n%s\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "$images" > "$set/Contents.json"
  echo "$name: $(du -ch "$set"/*.jpg | tail -1 | cut -f1)"
}

MISSING=0
write TourPad 540 "light dark"
write TourPhone 330 "light dark"
write TourMac 780 "light dark"
write TourWatch 420 "any"
exit $MISSING
