#!/bin/sh
# Prints the directory holding Sparkle's generate_keys / sign_update, downloading the release matching
# Package.resolved into .build/sparkle-tools once. sign_update reads the EdDSA private key, so the
# download must match a pinned checksum: add one here when Sparkle is bumped.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(python3 -c 'import json; print(next(p["state"]["version"] for p in json.load(open("Package.resolved"))["pins"] if p["identity"] == "sparkle"))')
DIR=.build/sparkle-tools/$VERSION
case "$VERSION" in
    2.10.1) SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27 ;;
    *) echo "No checksum pinned for Sparkle $VERSION in scripts/sparkle-tools.sh" >&2; exit 1 ;;
esac
if [ ! -x "$DIR/bin/sign_update" ]; then
    mkdir -p "$DIR"
    TARBALL="$DIR.tar.xz"
    curl -fsSL -o "$TARBALL" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
    echo "$SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { rm -f "$TARBALL"; echo "Sparkle $VERSION checksum mismatch" >&2; exit 1; }
    tar -xJf "$TARBALL" -C "$DIR"
    rm -f "$TARBALL"
fi
echo "$PWD/$DIR/bin"
