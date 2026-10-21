#!/bin/sh
# The runnable check: unit tests plus curl through a live proxy (HTTP, decrypted HTTPS, tunnel,
# breakpoints, Map Local/Remote, replay, app lookup), then a release build of the app.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
log=$(mktemp)
swift test >"$log" 2>&1 || { grep -E "error:|failed|Fatal" "$log" | head -40; echo "Tests failed (full log: $log)"; exit 1; }
grep -E "Executed .* tests" "$log" | tail -1
./make-app.sh
