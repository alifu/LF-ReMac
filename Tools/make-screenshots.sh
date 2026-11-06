#!/usr/bin/env bash
# Regenerates the README screenshots in docs/images from dummy data (Debug builds, `-screenshots` mode).
#   iPhone: XCUITest in the iPhone 17 Pro simulator taps through the app (iOSClientUITests).
#   Mac:    XCUITest launches the host in dummy-data mode; the app draws its own windows into the folder.
# Usage: Tools/make-screenshots.sh   (run from anywhere; needs Xcode, xcodegen, an iPhone 17 Pro simulator)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/docs/images"
SIMULATOR="iPhone 17 Pro"
mkdir -p "$OUT"

xcodegen generate >/dev/null

echo "==> iPhone screenshots"
xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
xcrun simctl status_bar "$SIMULATOR" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
TEST_RUNNER_SCREENSHOT_DIR="$OUT" xcodebuild -scheme iOSClientScreenshots \
  -destination "platform=iOS Simulator,name=$SIMULATOR,OS=26.5" test | tail -n 3

echo "==> Mac screenshots"
rm -f "$OUT/mac-pairing.png" "$OUT/mac-paired-devices.png"
TEST_RUNNER_SCREENSHOT_DIR="$OUT" xcodebuild -scheme MacHostScreenshots -destination 'platform=macOS' test | tail -n 3

for file in ios-hosts ios-stream mac-pairing mac-paired-devices; do
  [ -s "$OUT/$file.png" ] || { echo "missing $OUT/$file.png" >&2; exit 1; }
done
sips --resampleWidth 1600 "$OUT/ios-stream.png" >/dev/null   # the landscape shot is 2622 px wide; 1600 is plenty for a README
echo "Done: $OUT"
