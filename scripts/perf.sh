#!/usr/bin/env bash
# Performance budgets in isolation (serial, release build) and the real-app benchmark.
#   scripts/perf.sh          budget tests (fake terminals) — fails when a budget is exceeded
#   scripts/perf.sh --app    also runs dist/Corral.app headless (CORRAL_BENCH) with real terminals
set -euo pipefail
cd "$(dirname "$0")/.."
LOG=$(mktemp -t corral-perf)
swift build -c release --product corral-hook >/dev/null
if ! CORRAL_PERF=1 swift test -c release --no-parallel --filter 'PerformanceTests|SidebarDiffTests/planCostStaysFlat' \
        -Xswiftc -enable-testing -Xswiftc -plugin-path \
        -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing >"$LOG" 2>&1; then
    grep -E 'PERF|✘|↳|error:' "$LOG" | grep -v 'Testing Library\|Target Platform' >&2
    echo "perf budgets failed, full log: $LOG" >&2
    exit 1
fi
grep -E 'PERF' "$LOG"

if [[ "${1:-}" == "--app" ]]; then
    APP=dist/Corral.app/Contents/MacOS/Corral
    [[ -x "$APP" ]] || { echo "build the app first: scripts/bundle.sh" >&2; exit 1; }
    OUT=$(mktemp -t corral-bench).json
    CORRAL_BENCH="$OUT" "$APP"
    python3 - "$OUT" <<'PY'
import json, sys
for m in json.load(open(sys.argv[1])):
    print(f"{m['name']:22} p50 {m['p50']:9.2f} p95 {m['p95']:9.2f} max {m['max']:9.2f} {m['unit']}")
PY
fi
