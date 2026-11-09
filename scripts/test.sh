#!/usr/bin/env bash
# Runs all tests. The CLT don't find the swift-testing macro plugin on their own.
# corral-hook is built first: tests run the real C binary.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product corral-hook >/dev/null
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
