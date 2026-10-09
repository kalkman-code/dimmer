#!/bin/bash
# Launch check for a built Dimmer: open it with its Settings window up, confirm the window was shown
# and the app is still running five seconds later, then leave it running for the tester. Run after
# scripts/build-app.sh. Any other running Dimmer is quit first, because two copies fight over the
# backlight; pass --restore to quit the build afterwards and put /Applications/Dimmer.app back.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dimmer.app"
: "${APP:?}"
[ -d "$APP" ] || { printf 'No build at %s; run scripts/build-app.sh first.\n' "$APP" >&2; exit 1; }
if ! grep -a -q -- '--open-settings' "$APP/Contents/MacOS/Dimmer"; then
    printf 'This probe needs a debug build; release builds do not accept --open-settings.\n' >&2
    exit 1
fi

quit_dimmer() {
    osascript -e 'tell application id "uk.co.kalkmancode.Dimmer" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -f 'MacOS/Dimmer( |$)' >/dev/null || return 0; sleep 0.25; done
    printf 'Dimmer did not quit.\n' >&2
    exit 1
}

quit_dimmer
started="$(date '+%Y-%m-%d %H:%M:%S')"
# -n: LaunchServices otherwise resolves the bundle ID to /Applications/Dimmer.app and opens that copy.
open -n -g "$APP" --args --open-settings
sleep 5

pid="$(pgrep -f "$APP/Contents/MacOS/Dimmer" || true)"
shown="$(/usr/bin/log show --style compact --info --start "$started" \
    --predicate 'subsystem == "uk.co.kalkmancode.Dimmer" AND category == "settings"' 2>/dev/null | grep 'settings window shown' || true)"

if [ -z "$pid" ]; then
    printf 'FAIL: Dimmer is not running five seconds after opening Settings.\n' >&2
    open -g /Applications/Dimmer.app
    exit 1
fi
if [ -z "$shown" ]; then
    printf 'FAIL: Dimmer is running (pid %s) but never logged the Settings window.\n' "$pid" >&2
    exit 1
fi
# The first 1.1 builds opened Settings as a 28 pt title bar, then 0 pt wide; a shown window is not enough.
size="$(printf '%s' "$shown" | tail -1 | sed -nE 's/.*\{\{[-0-9.]+, [-0-9.]+\}, \{([0-9.]+), ([0-9.]+)\}\}.*/\1 \2/p')"
read -r width height <<<"${size:-0 0}"
if [ "${width%.*}" -lt 600 ] || [ "${height%.*}" -lt 400 ]; then
    printf 'FAIL: Settings window is %s x %s pt.\n' "$width" "$height" >&2
    exit 1
fi
printf 'PASS: Settings opened and Dimmer is still running (pid %s).\n%s\n' "$pid" "$shown"

if [ "${1:-}" = "--restore" ]; then
    quit_dimmer
    open -g /Applications/Dimmer.app
    printf 'Restored /Applications/Dimmer.app.\n'
fi
