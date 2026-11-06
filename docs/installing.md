# Installing LF-ReMac

LF-ReMac is two apps, and they are installed differently:

| App | How you get it |
|---|---|
| **LF-ReMac for Mac** (the host) | Homebrew cask from a personal tap (below), or build from source |
| **LF-ReMac for iPhone** (the viewer) | Build from source with Xcode and install it on your own iPhone. It is **not on the App Store or TestFlight** |

## Mac app (Homebrew)

```sh
brew install --cask alifu/tap/lf-remac
```

This adds the tap `alifu/homebrew-tap` and installs `LF-ReMac.app` into `/Applications`. Needs macOS 14 or later.

### First launch: Gatekeeper

The app is signed with a personal Apple developer certificate and is **not notarized** (notarizing needs a paid
Developer ID). macOS therefore blocks the first launch. Allow it once, either way:

- System Settings → Privacy & Security → scroll down → **Open Anyway** next to LF-ReMac, or
- in Terminal: `xattr -dr com.apple.quarantine /Applications/LF-ReMac.app`

(Homebrew no longer accepts un-notarized casks into its main repository, which is why this lives in a personal tap.)

### First start

1. Open LF-ReMac. It lives in the menu bar (no Dock icon).
2. Allow **Screen Recording** when macOS asks, and **Accessibility** if you want to control the Mac from the iPhone.
   Then relaunch once.
3. Choose **Start Hosting**, then **Pair New iPhone…** and scan the QR code with the iPhone app.

To start it at login, add it in System Settings → General → Login Items, as described in
[Keeping the Mac reachable](hosting-the-mac.md).

### Updating and removing

```sh
brew upgrade --cask lf-remac        # update
brew uninstall --cask lf-remac      # remove the app
brew uninstall --zap --cask lf-remac  # also remove its preferences
```

Updating keeps your pairings and permissions as long as releases are signed by the same developer team. The Mac's
security key and the list of paired iPhones live in the Keychain, so they survive an uninstall; to forget them
completely, delete the entries whose name starts with `com.alifu.lfremac` in Keychain Access.

Update the **Mac app first**, then the iPhone app: an older Mac app drops the connection from a newer iPhone app.

## iPhone app (from source)

The iPhone app is built with a **personal Apple developer account** and has not been published. To use it:

1. Clone this repository and install XcodeGen (`brew install xcodegen`).
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your own team ID (a free Personal Team works).
3. `xcodegen generate && open LF-ReMac.xcodeproj`, choose the **iOSClient** scheme and your iPhone, and run.

Apps signed with a free account stop opening after **7 days**; run it from Xcode again to renew it. A paid
Apple Developer Program membership extends this to a year and would allow TestFlight, but this project does not use one.

## Making a release (maintainer)

1. Raise `MARKETING_VERSION` in `project.yml` and commit.
2. Run `Tools/release.sh`. It archives the app in Release, checks the signature, and writes
   `dist/LF-ReMac-<version>.zip` and `dist/lf-remac.rb` (the cask with the right version and sha256).
   Use the same signing team every time.
3. Create a GitHub release tagged `v<version>` in this repository and attach the zip:
   `gh release create v<version> dist/LF-ReMac-<version>.zip --title "LF-ReMac <version>"`.
4. Copy `dist/lf-remac.rb` to `Casks/lf-remac.rb` in the `alifu/homebrew-tap` repository, commit and push.
5. Check from a clean state: `brew update && brew install --cask alifu/tap/lf-remac`.
