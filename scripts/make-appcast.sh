#!/bin/bash
# Builds Dimmer's signed Sparkle appcast for one new release. It writes files only; it never uploads.
#
#   SPARKLE_ED_KEY=<signing key> scripts/make-appcast.sh <final stapled Dimmer-X.Y.Z.dmg> <notes.html> <empty output dir> [<current appcast.xml>]
#
# Run it after the DMG is notarised and stapled: any later change to the DMG invalidates its signature.
# The key arrives through the environment and reaches Sparkle's tools only on standard input. Sparkle
# 2.10.0's tools print a key they cannot decode, so the key is checked in
# memory first and their output is captured and withheld; this script prints only its own fixed lines.
# Pass the live appcast as the fourth argument so earlier releases stay in the feed with their own URLs.
# Overrides for staged tests only: DIMMER_PUBLIC_KEY, DIMMER_DOWNLOAD_PREFIX (a URL template with {version}).
set -euo pipefail
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:?final stapled DMG}"
NOTES="${2:?release notes .html}"
OUT="${3:?empty output directory}"
PREVIOUS="${4:-}"
: "${SPARKLE_ED_KEY:?SPARKLE_ED_KEY is not set}"

BIN="$(find "$ROOT/.build/artifacts" -path '*/Sparkle/bin' -maxdepth 4 -type d 2>/dev/null | head -1 || true)"
[ -x "$BIN/generate_appcast" ] || { echo "Sparkle tools not found; run swift package resolve" >&2; exit 1; }
PUBLIC_KEY="${DIMMER_PUBLIC_KEY:-$(plutil -extract SUPublicEDKey raw "$ROOT/Resources/Info.plist")}"

NAME="$(basename "$DMG")"
VERSION="${NAME#Dimmer-}"; VERSION="${VERSION%.dmg}"
[[ "$NAME" =~ ^Dimmer-[0-9]+\.[0-9]+\.[0-9]+\.dmg$ ]] || { echo "Expected Dimmer-X.Y.Z.dmg, got $NAME" >&2; exit 1; }
[ -f "$NOTES" ] || { echo "Release notes not found: $NOTES" >&2; exit 1; }
# {version} keeps each release on its own tag's download URL; generate_appcast takes only one plain prefix.
GITHUB_TEMPLATE='https://github.com/kalkman-code/dimmer/releases/download/v{version}/'
TEMPLATE="${DIMMER_DOWNLOAD_PREFIX:-$GITHUB_TEMPLATE}"
PLACEHOLDER='{version}'
PREFIX="${TEMPLATE//"$PLACEHOLDER"/$VERSION}"

# The script changes directory below, and the release steps give these as paths relative to the repo root.
absolute() { printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
[ -f "$DMG" ] || { echo "DMG not found: $DMG" >&2; exit 1; }
DMG="$(absolute "$DMG")"
NOTES="$(absolute "$NOTES")"
[ -z "$PREVIOUS" ] || { [ -f "$PREVIOUS" ] || { echo "Current appcast not found: $PREVIOUS" >&2; exit 1; }; PREVIOUS="$(absolute "$PREVIOUS")"; }

if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then echo "$OUT is not empty" >&2; exit 1; fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$OUT"
# With a file named "-" present, --ed-key-file - reads that file instead of standard input.
[ ! -e ./- ] || { echo "Refusing: a file named '-' exists in $OUT" >&2; exit 1; }

if ! printf '%s\n' "$SPARKLE_ED_KEY" | swift "$ROOT/scripts/sparkle/key-check.swift" "$PUBLIC_KEY"; then
    echo "Key check failed; nothing was signed." >&2
    exit 1
fi

# The app inside the DMG must carry the same public key and version, or users could never verify it.
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
APP_KEY="$(plutil -extract SUPublicEDKey raw "$MOUNT/Dimmer.app/Contents/Info.plist" 2>/dev/null || true)"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$MOUNT/Dimmer.app/Contents/Info.plist")"
APP_BUILD="$(plutil -extract CFBundleVersion raw "$MOUNT/Dimmer.app/Contents/Info.plist")"
hdiutil detach "$MOUNT" -quiet; rmdir "$MOUNT"; trap - EXIT
[ "$APP_KEY" = "$PUBLIC_KEY" ] || { echo "The app in $NAME does not carry the expected SUPublicEDKey" >&2; exit 1; }
[ "$APP_VERSION" = "$VERSION" ] || { echo "The app in $NAME is version $APP_VERSION" >&2; exit 1; }

cp "$DMG" "$OUT/$NAME"
cp "$NOTES" "$OUT/Dimmer-$VERSION.html"
[ -z "$PREVIOUS" ] || cp "$PREVIOUS" "$OUT/appcast.xml"

set +e
LOG="$(printf '%s\n' "$SPARKLE_ED_KEY" | "$BIN/generate_appcast" --ed-key-file - \
    --download-url-prefix "$PREFIX" --embed-release-notes --maximum-deltas 0 --maximum-versions 0 \
    --versions "$APP_BUILD" "$OUT" 2>&1)"
STATUS=$?
set -e
unset LOG
if [ "$STATUS" -ne 0 ]; then
    echo "generate_appcast failed (exit $STATUS). Its output is withheld because it can contain key material." >&2
    exit 1
fi
rm -rf "$OUT/old_updates"

swift "$ROOT/scripts/sparkle/verify-appcast.swift" "$OUT/appcast.xml" "$PUBLIC_KEY" "$OUT" "$TEMPLATE"
echo "Appcast for $VERSION (build $APP_BUILD): $OUT/appcast.xml"
