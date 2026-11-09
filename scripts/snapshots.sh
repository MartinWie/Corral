#!/usr/bin/env bash
# Renders every snapshot gallery offscreen (invisible alpha-0 windows) into a directory.
#   scripts/snapshots.sh [out-dir]   default: dist/snapshots
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-dist/snapshots}
mkdir -p "$OUT"
LOG=$(mktemp -t corral-snap)
swift build --product corral-hook >/dev/null
# Only the galleries: they switch the global Motion flag, which other suites must not see.
if ! CORRAL_SNAPSHOTS="$(cd "$OUT" && pwd)" swift test -Xswiftc -plugin-path \
        -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
        --filter '(?i)snapshot|gallery' >"$LOG" 2>&1; then
    grep -E '✘|error:' "$LOG" | head -20 >&2
    echo "snapshot run failed, full log: $LOG" >&2
    exit 1
fi
ls "$OUT"
