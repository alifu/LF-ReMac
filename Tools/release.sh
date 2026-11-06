#!/usr/bin/env bash
# Builds the Mac app for release and prepares the Homebrew cask. Publishes nothing.
#
#   Tools/release.sh
#
# Output in dist/ (git-ignored):
#   LF-ReMac-<version>.zip   the app, zipped (attach it to the GitHub release v<version>)
#   lf-remac.rb              the cask, with this zip's version and sha256 (copy into the tap's Casks/)
#
# The version is MARKETING_VERSION in project.yml. The app is signed with the team in Config/Local.xcconfig;
# always release with the same team, or macOS asks again for Screen Recording and Accessibility.
# It is not notarized (no paid Developer ID), so Gatekeeper blocks a first launch; the cask's caveats and
# docs/installing.md explain how to allow it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)"
[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
REPO="alifu/LF-ReMac"
DIST="$PWD/dist"
ARCHIVE="$DIST/LF-ReMac.xcarchive"
ZIP="$DIST/LF-ReMac-$VERSION.zip"

rm -rf "$DIST"
mkdir -p "$DIST"
xcodegen generate >/dev/null

echo "==> Archiving LF-ReMac $VERSION (Release)"
xcodebuild -scheme MacHost -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" archive | tail -n 3
APP="$ARCHIVE/Products/Applications/LF-ReMac.app"
[ -d "$APP" ] || { echo "archive has no LF-ReMac.app" >&2; exit 1; }

echo "==> Checking the app"
codesign --verify --deep --strict "$APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
echo "bundle id $BUNDLE_ID, architectures: $(lipo -archs "$APP/Contents/MacOS/LF-ReMac")"
codesign -dv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=" | head -3

echo "==> Zipping"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

cat > "$DIST/lf-remac.rb" <<CASK
cask "lf-remac" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/LF-ReMac-#{version}.zip"
  name "LF-ReMac"
  desc "Private remote desktop host for the LF-ReMac iPhone app"
  homepage "https://github.com/$REPO"

  depends_on macos: :sonoma

  app "LF-ReMac.app"

  uninstall quit: "$BUNDLE_ID"

  zap trash: "~/Library/Preferences/$BUNDLE_ID.plist"

  caveats <<~EOS
    macOS blocks the first launch because LF-ReMac is not notarized. Open System Settings >
    Privacy & Security and choose "Open Anyway", or run:
      xattr -dr com.apple.quarantine /Applications/LF-ReMac.app

    On first start, allow Screen Recording (and Accessibility for remote control), then choose
    "Start Hosting" in the menu bar item.
  EOS
end
CASK

echo
echo "Version   $VERSION"
echo "Zip       $ZIP"
echo "sha256    $SHA"
echo "Cask      $DIST/lf-remac.rb"
