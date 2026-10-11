#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dimmer.app"
# "-" is ad hoc. A Developer ID identity (the release path) adds the hardened runtime and secure timestamps.
IDENTITY="${DIMMER_SIGN_IDENTITY:--}"

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
install -m 755 "$BIN" "$APP/Contents/MacOS/Dimmer"
if ! otool -l "$APP/Contents/MacOS/Dimmer" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Dimmer"
fi
# The universal build keeps a debug map of absolute object and source paths (the builder's home
# folder) in the binary; strip it.
strip -S -x "$APP/Contents/MacOS/Dimmer"
install -m 644 "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Release and staged-update builds set the version here, so the tracked plist is not edited per build.
[ -z "${DIMMER_VERSION:-}" ] || plutil -replace CFBundleShortVersionString -string "$DIMMER_VERSION" "$APP/Contents/Info.plist"
[ -z "${DIMMER_BUILD:-}" ] || plutil -replace CFBundleVersion -string "$DIMMER_BUILD" "$APP/Contents/Info.plist"
install -m 644 "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
install -m 644 "$ROOT/.build/checkouts/KeyboardShortcuts/license" "$APP/Contents/Resources/KeyboardShortcuts-LICENSE.txt"
SPARKLE_DIR="$(dirname "$(find "$ROOT/.build/artifacts" -path '*/Sparkle/Sparkle.xcframework' -maxdepth 4 -type d 2>/dev/null | head -1 || true)")"
SPARKLE="$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE" ] || { printf 'Sparkle.framework not found under .build/artifacts\n' >&2; exit 1; }
# ditto keeps the framework's Versions symlinks and executable bits.
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install -m 644 "$SPARKLE_DIR/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
BIN_DIR="$(dirname "$BIN")"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ "$IDENTITY" = "-" ]; then
    # Ad hoc code has no Team ID, so under the hardened runtime library validation would refuse to load
    # the embedded framework. Ad hoc builds are for local testing only; releases pass an identity.
    SIGN=(codesign --force --sign - --timestamp=none)
else
    SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
fi
# Inside out, per Sparkle's manual signing guide; --deep signing would drop the Downloader's entitlements.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$FW/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Autoupdate"
"${SIGN[@]}" "$FW/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --identifier uk.co.kalkmancode.Dimmer "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
printf 'Built %s\n' "$APP"
lipo -info "$APP/Contents/MacOS/Dimmer"
lipo -info "$FW/Sparkle"
