#!/usr/bin/env bash
# Builds libghostty (static) + its resources (shell integration, themes, terminfo) into
# vendor/ghostty-out. Without i18n (GNU libintl is LGPL, and Corral has no translated UI from it) and
# without Sentry (a crash reporter writing into Ghostty.app's own cache folders). Command Line Tools only: patches/ghostty-corral.patch makes Ghostty
# compile its Metal shaders at runtime (no Xcode `metal` tool) and install a plain static lib.
#   scripts/build-ghostty.sh            build pinned Ghostty
#   GHOSTTY_REF=v1.4.1 scripts/...      build another tag (patch must still apply)
set -euo pipefail
cd "$(dirname "$0")/.."

GHOSTTY_REF=${GHOSTTY_REF:-v1.4.0}
ZIG_VERSION=0.17.1
ZIG_SHA256=75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d
ZIG=vendor/zig-aarch64-macos-$ZIG_VERSION/zig

mkdir -p vendor
if [[ ! -d vendor/ghostty/.git ]]; then
    git clone --depth 1 --branch "$GHOSTTY_REF" https://github.com/ghostty-org/ghostty.git vendor/ghostty
fi
(
    cd vendor/ghostty
    # Edits in vendor/ghostty that aren't in the patch yet would be lost by the reset below.
    if ! git diff --quiet && ! git diff | cmp -s - ../../patches/ghostty-corral.patch; then
        echo "vendor/ghostty has edits not saved to patches/ghostty-corral.patch." >&2
        echo "Save them: git -C vendor/ghostty diff > patches/ghostty-corral.patch" >&2
        exit 1
    fi
    git fetch --depth 1 origin tag "$GHOSTTY_REF" 2>/dev/null || true
    git checkout -q -- .
    git checkout -q "$GHOSTTY_REF"
    git apply ../../patches/ghostty-corral.patch
)

# Ghostty pins its Zig version; keep it local so the system zig stays untouched.
if [[ ! -x "$ZIG" ]]; then
    tarball=vendor/zig-$ZIG_VERSION.tar.xz
    curl -fsSL -o "$tarball" "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
    echo "$ZIG_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || { rm -f "$tarball"; echo "zig checksum mismatch" >&2; exit 1; }
    tar xJf "$tarball" -C vendor
    rm -f "$tarball"
fi

rm -rf vendor/ghostty-out
(
    cd vendor/ghostty
    "../../$ZIG" build \
        -Doptimize=ReleaseFast \
        -Dapp-runtime=none \
        -Demit-xcframework=false \
        -Demit-macos-app=false \
        -Demit-docs=false \
        -Di18n=false \
        -Dsentry=false \
        -p ../ghostty-out
)
test -f vendor/ghostty-out/lib/libghostty.a
test -d vendor/ghostty-out/share/ghostty/shell-integration
echo "Built vendor/ghostty-out (libghostty.a + share/ghostty + share/terminfo)"
