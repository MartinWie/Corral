#!/usr/bin/env bash
# Builds dist/Corral.app from the SwiftPM products. Command Line Tools only (no Xcode).
#   scripts/bundle.sh            optimized build, signed with the Developer ID when the keychain has one,
#                                else "Corral Local Signing", else ad hoc
#   scripts/bundle.sh --install  also copies to /Applications
#   scripts/bundle.sh --release  for GitHub releases (scripts/release.sh notarizes it): committed source
#                                only, Developer ID + secure timestamp required, notices checked, debug
#                                symbols stripped, leak scan before signing
# Every build carries the update feed (GitHub Releases) and Sparkle's EdDSA public key; updates always
# ask before installing.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --release) RELEASE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $RELEASE == 1 && -n "$(git status --porcelain 2>/dev/null)" && "${CORRAL_ALLOW_DIRTY:-}" != 1 ]]; then
    echo "--release builds committed source only: commit or stash first (CORRAL_ALLOW_DIRTY=1 to override)." >&2
    exit 1
fi
# A stable identity keeps privacy grants (Desktop, Documents, …) across rebuilds and updates; an ad-hoc
# signature changes with every build, and macOS then denies silently what it allowed before.
# "Developer ID Application: Name (TEAMID)" is read from the keychain, never written here;
# CORRAL_RELEASE_IDENTITY picks one when several exist.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
DEVELOPER_ID="${CORRAL_RELEASE_IDENTITY:-$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)}"
[[ -n "$DEVELOPER_ID" && "$IDENTITIES" == *"\"$DEVELOPER_ID\""* ]] || DEVELOPER_ID=""
source scripts/signing-keychain.sh
# Hardened runtime with a Developer ID (notarization needs it, and library validation then accepts
# Sparkle re-signed by the same team). Never with the others: no team ID, so it would reject Sparkle.
RUNTIME=()
if [[ -n "$DEVELOPER_ID" ]]; then
    SIGN=(--sign "$DEVELOPER_ID")
    RUNTIME=(--options runtime)
    [[ $RELEASE == 1 ]] && RUNTIME+=(--timestamp)
elif [[ $RELEASE == 1 ]]; then
    echo "--release needs a \"Developer ID Application\" certificate in the keychain. Nothing built." >&2
    exit 1
elif corral_unlock_signing; then
    SIGN=(--keychain "$CORRAL_KEYCHAIN" --sign "$CORRAL_IDENTITY")
else
    SIGN=(--sign -)
    echo "note: signing ad hoc; run scripts/make-signing-identity.sh once so privacy grants survive rebuilds" >&2
fi
FEED_URL="https://github.com/MartinWie/Corral/releases/latest/download/appcast.xml"
ED_KEY=$(cat Resources/app/sparkle-public-key)

if [[ ! -f vendor/ghostty-out/lib/libghostty.a ]]; then
    echo "libghostty missing: run scripts/build-ghostty.sh first" >&2
    exit 1
fi

# The manifest only includes the app when libghostty.a exists; SwiftPM caches manifest
# evaluation, so skip the cache or a build from before libghostty existed hides the target.
LOG=$(mktemp -t corral-bundle)
if ! swift build -c release --manifest-cache none --product Corral >"$LOG" 2>&1 \
   || ! swift build -c release --manifest-cache none --product corral-hook >>"$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | head -20 >&2
    echo "build failed, full log: $LOG" >&2
    exit 1
fi
BIN=$(swift build -c release --manifest-cache none --show-bin-path)

APP=dist/Corral.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Corral" "$APP/Contents/MacOS/Corral"
cp "$BIN/corral-hook" "$APP/Contents/MacOS/corral-hook"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Its XPC services are only for sandboxed apps (SUEnableInstallerLauncherService / SUEnableDownloaderService).
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp Resources/app/AppIcon.icns "$APP/Contents/Resources/"
# Ghostty looks for Contents/Resources/{ghostty,terminfo} next to the binary.
cp -R vendor/ghostty-out/share/ghostty "$APP/Contents/Resources/ghostty"
cp -R vendor/ghostty-out/share/terminfo "$APP/Contents/Resources/terminfo"

# Marketing version from VERSION; the build number counts commits (numeric, always increasing);
# the exact source goes into CorralCommit (-dirty: uncommitted changes were built).
VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || COMMIT="$COMMIT-dirty"
# Licenses of what the binary links (Ghostty, its libraries, fonts), and the About panel's credits.
cp Resources/app/THIRD_PARTY_NOTICES.txt Resources/app/Credits.html "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.corral.app</string>
    <key>CFBundleName</key><string>Corral</string>
    <key>CFBundleDisplayName</key><string>Corral</string>
    <key>CFBundleExecutable</key><string>Corral</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CorralCommit</key><string>${COMMIT}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>SUFeedURL</key><string>${FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <!-- Every update asks first: no silent installs, and no option to turn them on. -->
    <key>SUAllowsAutomaticUpdates</key><false/>
    <!-- Privacy prompts for programs running in Corral's terminals (macOS attributes them to Corral). -->
    <key>NSDesktopFolderUsageDescription</key><string>A program running within Corral would like to access files in your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>A program running within Corral would like to access files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>A program running within Corral would like to access files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>A program running within Corral would like to access files on a removable volume.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>A program running within Corral would like to access files on a network volume.</string>
    <key>NSAppleEventsUsageDescription</key><string>A program running within Corral would like to use AppleScript.</string>
    <key>NSAudioCaptureUsageDescription</key><string>A program running within Corral would like to access your system's audio.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>A program running within Corral would like to use Bluetooth.</string>
    <key>NSCalendarsUsageDescription</key><string>A program running within Corral would like to access your Calendar.</string>
    <key>NSCameraUsageDescription</key><string>A program running within Corral would like to use the camera.</string>
    <key>NSContactsUsageDescription</key><string>A program running within Corral would like to access your Contacts.</string>
    <key>NSLocalNetworkUsageDescription</key><string>A program running within Corral would like to access the local network.</string>
    <key>NSLocationUsageDescription</key><string>A program running within Corral would like to access your location information.</string>
    <key>NSMicrophoneUsageDescription</key><string>A program running within Corral would like to use your microphone.</string>
    <key>NSMotionUsageDescription</key><string>A program running within Corral would like to access motion data.</string>
    <key>NSPhotoLibraryUsageDescription</key><string>A program running within Corral would like to access your Photo Library.</string>
    <key>NSRemindersUsageDescription</key><string>A program running within Corral would like to access your reminders.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>A program running within Corral would like to use speech recognition.</string>
    <key>NSSystemAdministrationUsageDescription</key><string>A program running within Corral requires elevated privileges.</string>
</dict>
</plist>
PLIST

if [[ $RELEASE == 1 ]]; then
    # Every library family the binary links has a notice, and nothing LGPL or Sentry slipped in (a
    # vendor/ghostty-out from before the build options changed). Needs the symbols, so before stripping.
    scripts/notices.py --check "$APP/Contents/MacOS/Corral"
    # Debug symbols hold this Mac's absolute source and object paths: kept in dist/ for crash reports.
    rm -rf "dist/Corral-$VERSION.dSYM"
    dsymutil "$APP/Contents/MacOS/Corral" -o "dist/Corral-$VERSION.dSYM" 2>/dev/null || true
    strip -S -x "$APP/Contents/MacOS/Corral" "$APP/Contents/MacOS/corral-hook"
    # Before signing: the Developer ID certificate in the signature carries the developer's name.
    scripts/leak-scan.py "$APP"
fi
# Inside out, as Sparkle documents: its helpers, the framework, the hook, then the app. The
# entitlements keep what programs in Corral's terminals may ask for under the hardened runtime
# (camera, microphone, contacts, AppleScript…): macOS attributes it to Corral.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force "${RUNTIME[@]+"${RUNTIME[@]}"}" "${SIGN[@]}" "$item"
done
codesign --force "${RUNTIME[@]+"${RUNTIME[@]}"}" "${SIGN[@]}" --identifier dev.corral.hook "$APP/Contents/MacOS/corral-hook"
ENTITLEMENTS=()
[[ ${#RUNTIME[@]} -gt 0 ]] && ENTITLEMENTS=(--entitlements Resources/app/Corral.entitlements)
codesign --force "${RUNTIME[@]+"${RUNTIME[@]}"}" "${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"}" "${SIGN[@]}" \
    --identifier dev.corral.app "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($VERSION, build $BUILD), signed with ${SIGN[${#SIGN[@]}-1]}"

if [[ $INSTALL == 1 ]]; then
    # Copy beside, then swap with two renames: a running Corral keeps finding its resources
    # (new terminals read Ghostty's shell integration from the bundle). Takes effect on relaunch.
    rm -rf /Applications/.Corral.app.new /Applications/.Corral.app.old
    cp -R "$APP" /Applications/.Corral.app.new
    [[ -d /Applications/Corral.app ]] && mv /Applications/Corral.app /Applications/.Corral.app.old
    mv /Applications/.Corral.app.new /Applications/Corral.app
    rm -rf /Applications/.Corral.app.old
    echo "Installed /Applications/Corral.app"
fi
