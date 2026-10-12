#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
STATE="${2:-}"
DURATION="${3:-300}"
VEIL_DELAY="${4:-15}"

usage() { printf 'Usage: %s withSensor|sensorless rest|veil [seconds] [veil-start-delay-seconds]\n' "$0" >&2; }
case "$MODE" in
    withSensor|sensorless) ;;
    *) usage; exit 2 ;;
esac
case "$STATE" in
    rest|veil) ;;
    *) usage; exit 2 ;;
esac
[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION > 0 )) || { printf 'Duration must be a positive number of seconds.\n' >&2; exit 2; }
[[ "$VEIL_DELAY" =~ ^[0-9]+$ ]] && (( VEIL_DELAY > 0 )) || { printf 'Veil start delay must be a positive number of seconds.\n' >&2; exit 2; }

PIDS="$(pgrep -x Dimmer || true)"
[[ "$PIDS" != *$'\n'* && -n "$PIDS" ]] || { printf 'Expected one running Dimmer process; found multiple or none.\n' >&2; exit 1; }
PID="$PIDS"
ARGS="$(ps -p "$PID" -o command=)"
EXECUTABLE="$(lsof -a -p "$PID" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
[[ "$EXECUTABLE" == "$ROOT"/* ]] || { printf 'Dimmer executable is outside this worktree: %s\n' "$EXECUTABLE" >&2; exit 1; }
if [[ "$MODE" == sensorless ]] && [[ "$ARGS" != *--force-sensorless* ]]; then
    printf 'Dimmer is not running with --force-sensorless.\n' >&2
    exit 1
fi
if [[ "$MODE" == withSensor ]] && [[ "$ARGS" == *--force-sensorless* ]]; then
    printf 'Dimmer is running in forced sensorless mode.\n' >&2
    exit 1
fi

OUT="$ROOT/build/performance-$MODE-$STATE"
mkdir -p "$OUT"
printf 'mode=%s\nstate=%s\npid=%s\nexecutable=%s\ndurationSeconds=%s\ncommand=%s\n' \
    "$MODE" "$STATE" "$PID" "$EXECUTABLE" "$DURATION" "$ARGS" > "$OUT/run.txt"

LOG_PID=""
TOP_PID=""
cleanup() {
    [[ -z "$TOP_PID" ]] || kill "$TOP_PID" 2>/dev/null || true
    [[ -z "$LOG_PID" ]] || kill "$LOG_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$STATE" == veil ]]; then
    log stream --style compact --predicate 'process == "Dimmer" AND (eventMessage CONTAINS "veil overlay" OR eventMessage CONTAINS "veil gone after")' \
        > "$OUT/veil-events.log" 2>&1 &
    LOG_PID=$!
    sleep 2
    printf 'Press Ctrl+Cmd+P now. Sampling begins in %s seconds; leave the Mac untouched until it finishes.\n' "$VEIL_DELAY"
    sleep "$VEIL_DELAY"
fi

vmmap --summary "$PID" > "$OUT/vmmap-summary.txt"
top -l "$((DURATION + 1))" -s 1 -pid "$PID" -stats pid,cpu,idlew > "$OUT/top-idlew.txt" &
TOP_PID=$!
: > "$OUT/process-samples.txt"
for (( sample=0; sample<DURATION; sample++ )); do
    RSS="$(ps -p "$PID" -o rss=)"
    printf '%s %s\n' "$(date +%s)" "$RSS" >> "$OUT/process-samples.txt"
    sleep 1
done
wait "$TOP_PID"
TOP_PID=""

awk '{ rss += $2; n++ } END { if (n) printf "meanRSSMB=%.2f\nsamples=%d\n", rss/n/1024, n }' \
    "$OUT/process-samples.txt" > "$OUT/process-means.txt"
awk -v pid="$PID" '
    $1 == "PID" {
        cpuColumn = 0
        wakeColumn = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "CPU" || $i == "%CPU") cpuColumn = i
            if ($i == "IDLEW") wakeColumn = i
        }
        next
    }
    cpuColumn && $1 == pid {
        count++
        if (count > 1) {
            cpuSum += $cpuColumn
            wakeSum += $wakeColumn
            wakeSamples++
        }
    }
    END {
        if (count < 2 || !cpuColumn || !wakeColumn) exit 1
        intervals = count - 1
        printf "meanCPUPercent=%.3f\n", cpuSum / intervals
        if (wakeSamples && wakeSum > 0) {
            printf "idleWakeupsPerSecond=%.3f\n", wakeSum / wakeSamples
        } else {
            printf "idleWakeupsPerSecond=null\n"
        }
        printf "topSamples=%d\n", count
    }
' "$OUT/top-idlew.txt" > "$OUT/resource-means.txt" || {
    printf 'Could not calculate CPU and idle wakeup means from top output.\n' >&2
    exit 1
}

if [[ "$STATE" == veil ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
    LOG_PID=""
    if ! grep -Eq 'veil overlay \+0\.5s .*visible=true onScreen=true' "$OUT/veil-events.log"; then
        printf 'Veil was not confirmed visible on screen after activation; discard this run.\n' >&2
        exit 1
    fi
    if grep -q 'veil gone after' "$OUT/veil-events.log"; then
        printf 'Veil cleared during sampling; discard this run.\n' >&2
        exit 1
    fi
fi
kill -0 "$PID" 2>/dev/null || { printf 'Dimmer exited during sampling; discard this run.\n' >&2; exit 1; }

if [[ -d "$ROOT/build/Dimmer.app" ]]; then du -sm "$ROOT/build/Dimmer.app" > "$OUT/app-size.txt"; fi
if [[ -f "$ROOT/build/Dimmer.dmg" ]]; then du -sm "$ROOT/build/Dimmer.dmg" > "$OUT/dmg-size.txt"; fi
cat "$OUT/run.txt" "$OUT/process-means.txt" "$OUT/resource-means.txt"
printf 'vmmap snapshot: %s\nRSS samples: %s\ntop samples: %s\n' \
    "$OUT/vmmap-summary.txt" "$OUT/process-samples.txt" "$OUT/top-idlew.txt"
if [[ "$STATE" == veil ]]; then printf 'veil verification: %s\n' "$OUT/veil-events.log"; fi
