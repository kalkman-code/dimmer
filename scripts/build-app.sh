#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dimmer.app"

cd "$ROOT"

XCODE_VERSION="$(xcodebuild -version)"
printf '%s\n' "$XCODE_VERSION"
if printf '%s\n' "$XCODE_VERSION" | grep -Eqi 'beta|release candidate|(^|[^[:alnum:]])RC([^[:alnum:]]|$)'; then
    printf 'Refusing to build with a pre-release Xcode toolchain.\n' >&2
    exit 1
fi
swift --version

swift build -c release --product Dimmer --arch arm64 --arch x86_64
BIN="$(swift build -c release --product Dimmer --arch arm64 --arch x86_64 --show-bin-path)/Dimmer"

: "${APP:?}"
rm -rf -- "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN" "$APP/Contents/MacOS/Dimmer"
# The universal build keeps a debug map of absolute object and source paths (the builder's home
# folder) in the binary; strip it.
strip -S -x "$APP/Contents/MacOS/Dimmer"
install -m 644 "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
printf 'Built %s\n' "$APP"
lipo -info "$APP/Contents/MacOS/Dimmer"
