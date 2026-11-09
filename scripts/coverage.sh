#!/usr/bin/env bash
# Runs all tests with coverage and enforces the line-coverage gate on the unit-testable
# targets (CorralCore, CorralKit). The libghostty glue (Sources/Corral) needs the real engine
# and is measured by the app bench instead.
#   scripts/coverage.sh [min-percent]   default 90
set -euo pipefail
cd "$(dirname "$0")/.."
MIN=${1:-90}
LOG=$(mktemp -t corral-cov)
swift build --product corral-hook >/dev/null
if ! swift test --enable-code-coverage -Xswiftc -plugin-path \
        -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing >"$LOG" 2>&1; then
    grep -E 'error:|✘' "$LOG" | head -30 >&2
    echo "tests failed, full log: $LOG" >&2
    exit 1
fi
# SwiftPM exports coverage for one test bundle only; merge the raw profiles and export
# across every test bundle so CorralKit is measured too.
DIR=$(dirname "$(swift test --show-codecov-path 2>/dev/null)")
xcrun llvm-profdata merge -sparse "$DIR"/*.profraw -o "$DIR/all.profdata"
OBJECTS=()
for bundle in .build/out/Products/Debug/*Tests.xctest; do
    OBJECTS+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
done
JSON="$DIR/all.json"
xcrun llvm-cov export -instr-profile "$DIR/all.profdata" "${OBJECTS[@]}" -ignore-filename-regex '\.build|Tests/' >"$JSON"
rm -f "$DIR"/*.profraw
python3 - "$JSON" "$MIN" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
minimum = float(sys.argv[2])
targets = {}
rows = []
for f in data["data"][0]["files"]:
    name = f["filename"]
    if "/Sources/" not in name:
        continue
    rel = name.split("/Sources/")[1]
    target = rel.split("/")[0]
    l = f["summary"]["lines"]
    t = targets.setdefault(target, [0, 0])
    t[0] += l["covered"]; t[1] += l["count"]
    rows.append((l["percent"], l["covered"], l["count"], rel))
for p, c, n, rel in sorted(rows):
    print(f"{p:6.1f}%  {c:5}/{n:<5} {rel}")
print()
gated = [t for t in targets if t in ("CorralCore", "CorralKit")]
cov = sum(targets[t][0] for t in gated); cnt = sum(targets[t][1] for t in gated)
for t, (c, n) in sorted(targets.items()):
    print(f"{t:12} {100*c/n:6.1f}%  ({c}/{n} lines)")
total = 100 * cov / cnt
print(f"{'GATED':12} {total:6.1f}%  (CorralCore + CorralKit, minimum {minimum:.0f}%)")
sys.exit(0 if total >= minimum else 1)
PY
