#!/bin/sh
# Builds Sekisho and installs it in /Applications.
set -eu
cd "$(dirname "$0")/.."
./make-app.sh >/dev/null
# Quit, never kill: quitting puts the macOS proxy back if Sekisho had switched it on.
if pgrep -x Sekisho >/dev/null; then
  osascript -e 'quit app "Sekisho"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Sekisho >/dev/null || break; sleep 0.5; done
  pkill -TERM -x Sekisho 2>/dev/null || true
  sleep 1
fi
rm -rf /Applications/Sekisho.app
ditto build/Sekisho.app /Applications/Sekisho.app
echo "Installed /Applications/Sekisho.app"
