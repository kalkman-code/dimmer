#!/bin/bash
# Design review: write PNGs of the built app's own Settings window. The app renders the window itself,
# so this needs no Screen Recording permission and captures nothing else on the screen.
#   scripts/snapshot-settings.sh <folder> launch      quit any Dimmer, open the build with Settings up
#   scripts/snapshot-settings.sh <folder> <name.png>  snapshot the running build's window
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dimmer.app"
DIR="${1:?folder}"
ACTION="${2:?launch or a file name ending .png}"
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"

if [ "$ACTION" = launch ]; then
    osascript -e 'tell application id "uk.co.kalkmancode.Dimmer" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -f 'MacOS/Dimmer( |$)' >/dev/null || break; sleep 0.25; done
    # -n: LaunchServices otherwise resolves the bundle ID to /Applications/Dimmer.app.
    open -n -g "$APP" --args --open-settings --snapshot-dir "$DIR"
    sleep 3
    exit 0
fi

rm -f "$DIR/$ACTION"
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"uk.co.kalkmancode.Dimmer.snapshot\"), object: \"$ACTION\", userInfo: nil, deliverImmediately: true)" 2>/dev/null
for _ in $(seq 1 20); do [ -s "$DIR/$ACTION" ] && break; sleep 0.25; done
[ -s "$DIR/$ACTION" ] || { printf 'No snapshot written; is the build running with Settings open?\n' >&2; exit 1; }
printf '%s\n' "$DIR/$ACTION"
