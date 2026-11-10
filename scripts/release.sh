#!/usr/bin/env bash
# Publishes VERSION as a GitHub release: a notarized DMG for first installs, a zip that installed copies
# update to (Sparkle, after asking), and appcast.xml.
#   scripts/release.sh          notes from release-notes/<version>.md (Markdown: "- " lines and paragraphs)
#   CORRAL_SKIP_TESTS=1 ...     when the suite just ran on this commit
# Notarization: APPLE_ID + TEAM_ID + NOTARY_PASSWORD (app-specific password) in the environment, else the
# notarytool keychain profile CORRAL_NOTARY_PROFILE (default corral-notary).
# The feed is releases/latest/download/appcast.xml, so each release carries the appcast for itself.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=MartinWie/Corral
VERSION=$(cat VERSION)
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"

[[ -z "$(git status --porcelain)" ]] || { echo "Uncommitted changes: commit first, releases build committed source." >&2; exit 1; }
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "HEAD isn't origin/main: push first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "$TAG exists: bump VERSION." >&2; exit 1
fi
[[ -f "$NOTES" ]] || { echo "$NOTES missing." >&2; exit 1; }

# Everything that can fail late is checked before the build.
SPARKLE_BIN=$(scripts/sparkle-tools.sh)
if [[ "$("$SPARKLE_BIN/generate_keys" --account corral -p 2>/dev/null)" != "$(cat Resources/app/sparkle-public-key)" ]]; then
    echo "The keychain's Sparkle key (account corral) doesn't match Resources/app/sparkle-public-key:" >&2
    echo "installed copies would reject this update. Import the right key: generate_keys --account corral -f <file>" >&2
    exit 1
fi
if [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    NOTARY=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD")
else
    NOTARY=(--keychain-profile "${CORRAL_NOTARY_PROFILE:-corral-notary}")
fi
xcrun notarytool history "${NOTARY[@]}" >/dev/null 2>&1 \
    || { echo "Notarization credentials don't work (see the top of this script)." >&2; exit 1; }

notarize() {
    local result status id
    result=$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --output-format json) || true
    status=$(/usr/bin/plutil -extract status raw - <<<"$result" 2>/dev/null || echo unknown)
    if [[ "$status" != Accepted ]]; then
        echo "Notarization of $1: $status" >&2
        echo "$result" >&2
        id=$(/usr/bin/plutil -extract id raw - <<<"$result" 2>/dev/null || true)
        if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${NOTARY[@]}" >&2; fi
        exit 1
    fi
}

# Right after approval the ticket may not be fetchable yet: retry before failing (loudly).
staple() {
    local attempt
    for attempt in 1 2 3 4 5 6; do
        xcrun stapler staple -q "$1" && return 0
        sleep 10
    done
    xcrun stapler staple "$1"
}

mkdir -p dist
if [[ "${CORRAL_SKIP_TESTS:-}" != 1 ]]; then
    scripts/test.sh >dist/release-tests.log 2>&1 || { echo "Tests failed: dist/release-tests.log" >&2; exit 1; }
fi
# Developer ID, hardened runtime, timestamp; leak-scanned before signing.
scripts/bundle.sh --release
APP=dist/Corral.app
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')
[[ -n "$IDENTITY" ]] || { echo "$APP isn't signed with a Developer ID." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# ditto keeps the bundle's signature intact (a plain zip can break it: "Corral is damaged").
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
notarize "$WORK/notarize.zip"
staple "$APP"
spctl -a -t exec "$APP"

# Sparkle's archive. No extended attributes (provenance, quarantine); the signature uses none.
ZIP=dist/Corral-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
ditto -x -k "$ZIP" "$WORK/check"
codesign --verify --strict --deep "$WORK/check/Corral.app"

# First installs: drag Corral onto Applications.
DMG=dist/Corral-$VERSION.dmg
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Corral.app"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname Corral -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
staple "$DMG"
spctl -a -t open --context context:primary-signature "$DMG"

SIGNATURE=$("$SPARKLE_BIN/sign_update" --account corral -p "$ZIP")
case "$SIGNATURE" in ''|*[[:space:]]*|*\"*) echo "Unexpected sign_update output: $SIGNATURE" >&2; exit 1 ;; esac

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
python3 -I - "$VERSION" "$(plist CFBundleVersion)" "$(plist LSMinimumSystemVersion)" "$(stat -f %z "$ZIP")" \
    "$SIGNATURE" "$REPO" "$NOTES" >dist/appcast.xml <<'PY'
import email.utils, html, sys
version, build, minimum, length, signature, repo, notes = sys.argv[1:]
body, items = [], []
for line in open(notes, encoding="utf-8").read().splitlines():
    line = line.strip()
    if line.startswith("- "):
        items.append(f"<li>{html.escape(line[2:])}</li>")
        continue
    if items:
        body.append("<ul>" + "".join(items) + "</ul>")
        items = []
    if line and not line.startswith("#"):
        body.append(f"<p>{html.escape(line)}</p>")
if items:
    body.append("<ul>" + "".join(items) + "</ul>")
url = f"https://github.com/{repo}/releases/download/v{version}/Corral-{version}.zip"
print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Corral</title>
    <item>
      <title>Corral {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>https://github.com/{repo}/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{"".join(body)}]]></description>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>""")
PY
scripts/leak-scan.py --skip-xattrs dist/appcast.xml

gh release create "$TAG" "$DMG" "$ZIP" dist/appcast.xml -R "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Corral $VERSION" --notes-file "$NOTES"
git fetch -q origin --tags
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
