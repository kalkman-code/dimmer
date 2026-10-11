#!/bin/bash
# Proves a two-version Sparkle update headlessly: a 1.3.0 test bundle updates to 1.3.1 from a local signed
# appcast, through Sparkle's own sparkle-cli, without launching Dimmer or showing a window.
#
#   SPARKLE_CLI=<sparkle.app/Contents/MacOS/sparkle> scripts/stage-update-test.sh <empty work dir>
#
# sparkle-cli is not in the SwiftPM artefact; build it from the matching tag:
#   git clone --depth 1 --branch 2.10.0 https://github.com/sparkle-project/Sparkle.git src
#   xcodebuild -project src/Sparkle.xcodeproj -scheme sparkle-cli -configuration Release -derivedDataPath dd build
# The test bundles use their own bundle ID (uk.co.kalkmancode.Dimmer.staging), a throwaway EdDSA key that
# never touches the Keychain, and a feed on 127.0.0.1, so nothing of the real app, its settings or its key
# is involved. Set DIMMER_SIGN_IDENTITY to run the same proof with Developer ID signatures.
set -euo pipefail
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${1:?empty work directory}"
CLI="${SPARKLE_CLI:?path to the sparkle-cli executable}"
STAGING_ID=uk.co.kalkmancode.Dimmer.staging
if [ -e "$W" ] && [ -n "$(ls -A "$W")" ]; then echo "$W is not empty" >&2; exit 1; fi
mkdir -p "$W"
W="$(cd "$W" && pwd)"
: "${W:?}"

PASS=0; FAIL=0
result() { if [ "$1" = ok ]; then PASS=$((PASS + 1)); echo "ok   $2"; else FAIL=$((FAIL + 1)); echo "FAIL $2"; fi; }
SERVER=""
cleanup() {
    [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
    for id in "$STAGING_ID" "$STAGING_ID".tampered-feed "$STAGING_ID".future "$STAGING_ID".tampered-archive; do
        defaults delete "$id" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

TEST_KEY="$(openssl rand -base64 32)"
cat > "$W/derive.swift" <<'SWIFT'
import CryptoKit
import Foundation
let seed = Data(base64Encoded: readLine()!)!
print(try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
SWIFT
TEST_PUBLIC="$(printf '%s\n' "$TEST_KEY" | swift "$W/derive.swift")"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"

if [ "${DIMMER_SIGN_IDENTITY:--}" = "-" ]; then
    RESIGN=(codesign --force --sign - --timestamp=none)
else
    RESIGN=(codesign --force --sign "$DIMMER_SIGN_IDENTITY" --options runtime --timestamp)
fi

# stage <version> <build> <destination> [<minimum macOS>]
stage() {
    DIMMER_VERSION="$1" DIMMER_BUILD="$2" "$ROOT/scripts/build-app.sh" > "$W/build-$1.log" 2>&1
    mkdir -p "$3"
    ditto "$ROOT/build/Dimmer.app" "$3/Dimmer.app"
    local plist="$3/Dimmer.app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$STAGING_ID" "$plist"
    plutil -replace SUPublicEDKey -string "$TEST_PUBLIC" "$plist"
    plutil -replace SUFeedURL -string "$BASE/feed/appcast.xml" "$plist"
    [ -z "${4:-}" ] || plutil -replace LSMinimumSystemVersion -string "$4" "$plist"
    "${RESIGN[@]}" --identifier "$STAGING_ID" "$3/Dimmer.app"
    codesign --verify --deep --strict "$3/Dimmer.app"
}

dmg() {
    local root="$W/dmgroot-$2"
    mkdir -p "$root" "$(dirname "$3")"
    ditto "$1" "$root/Dimmer.app"
    ln -s /Applications "$root/Applications"
    hdiutil create -volname "Dimmer $2" -srcfolder "$root" -fs HFS+ -format UDZO -ov "$3" >/dev/null
    rm -rf -- "${root:?}"
}

# A copy of the 1.3.0 bundle under its own bundle ID: Sparkle keys its installer session by bundle ID, and a
# refused install left running for one case made the next case fail with "Failed to resume installing update".
variant() {
    ditto "$W/old/Dimmer.app" "$W/$1/Dimmer.app"
    plutil -replace CFBundleIdentifier -string "$STAGING_ID.$1" "$W/$1/Dimmer.app/Contents/Info.plist"
    "${RESIGN[@]}" --identifier "$STAGING_ID.$1" "$W/$1/Dimmer.app" 2>/dev/null
}

version_of() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist"; }

stage 1.3.0 1300 "$W/old"
stage 1.3.1 1301 "$W/new"
stage 1.3.1 1301 "$W/future-os" 99.0
# An untouched 1.3.0 copy for the hands-on GUI pass; this script never opens it.
ditto "$W/old/Dimmer.app" "$W/gui-1.3.0/Dimmer.app"
result ok "built 1.3.0 and 1.3.1 test bundles with nested Sparkle helpers signed ($(codesign -dvv "$W/new/Dimmer.app" 2>&1 | sed -n 's/^Authority=//p;s/^Signature=//p' | head -1))"

dmg "$W/old/Dimmer.app" 1.3.0 "$W/archives/Dimmer-1.3.0.dmg"
dmg "$W/new/Dimmer.app" 1.3.1 "$W/archives/Dimmer-1.3.1.dmg"
dmg "$W/future-os/Dimmer.app" 1.3.1 "$W/archives-future/Dimmer-1.3.1.dmg"
for v in 1.3.0 1.3.1; do
    printf '<h2>Dimmer %s (staged test)</h2>\n<p>Local staging build used to prove the update path.</p>\n' "$v" > "$W/notes-$v.html"
done

# Two releases in turn, as the release manager runs them: 1.3.0 alone, then 1.3.1 added to the live feed.
# Each archive sits under its own version folder, as GitHub serves each tag's assets.
export SPARKLE_ED_KEY="$TEST_KEY" DIMMER_PUBLIC_KEY="$TEST_PUBLIC" DIMMER_DOWNLOAD_PREFIX="$BASE/v{version}/"
"$ROOT/scripts/make-appcast.sh" "$W/archives/Dimmer-1.3.0.dmg" "$W/notes-1.3.0.html" "$W/out-1.3.0" > "$W/make-appcast-1.3.0.log" 2>&1 \
    && "$ROOT/scripts/make-appcast.sh" "$W/archives/Dimmer-1.3.1.dmg" "$W/notes-1.3.1.html" "$W/out-1.3.1" "$W/out-1.3.0/appcast.xml" > "$W/make-appcast.log" 2>&1 \
    && result ok "make-appcast signed and verified 1.3.0, then 1.3.1 on top of it" || result fail "make-appcast (see $W/make-appcast*.log)"
# The release steps run it from the repo root with relative paths; the script changes directory internally.
(cd "$W" && "$ROOT/scripts/make-appcast.sh" archives/Dimmer-1.3.1.dmg notes-1.3.1.html out-relative out-1.3.0/appcast.xml) > "$W/make-appcast-relative.log" 2>&1 \
    && [ "$(grep -c '<item>' "$W/out-relative/appcast.xml")" = 2 ] \
    && result ok "make-appcast takes relative paths and builds the same feed" || result fail "make-appcast with relative paths (see $W/make-appcast-relative.log)"
[ "$(grep -c '<item>' "$W/out-1.3.1/appcast.xml")" = 2 ] && grep -q "url=\"$BASE/v1.3.0/Dimmer-1.3.0.dmg\"" "$W/out-1.3.1/appcast.xml" \
    && grep -q "url=\"$BASE/v1.3.1/Dimmer-1.3.1.dmg\"" "$W/out-1.3.1/appcast.xml" \
    && result ok "the second feed keeps 1.3.0 on its own download URL beside 1.3.1" || result fail "earlier release not preserved in the feed"
mkdir -p "$W/www/feed" "$W/www/v1.3.0" "$W/www/v1.3.1"
cp "$W/out-1.3.1/appcast.xml" "$W/www/feed/appcast.xml"
cp "$W/archives/Dimmer-1.3.0.dmg" "$W/www/v1.3.0/"
cp "$W/archives/Dimmer-1.3.1.dmg" "$W/www/v1.3.1/"

if DIMMER_DOWNLOAD_PREFIX="$BASE/future/v{version}/" "$ROOT/scripts/make-appcast.sh" "$W/archives-future/Dimmer-1.3.1.dmg" "$W/notes-1.3.1.html" "$W/out-future" > "$W/make-appcast-future.log" 2>&1; then
    result fail "verify-appcast should reject a feed whose minimum macOS is not 14.0"
else
    grep -q 'FAIL 1.3.1 (1301): minimum macOS is 14.0' "$W/make-appcast-future.log" \
        && result ok "verify-appcast rejects a feed whose minimum macOS is not 14.0" || result fail "future-OS feed failed for another reason"
fi
mkdir -p "$W/www/future"
cp "$W/out-future/appcast.xml" "$W/www/future/appcast.xml"

DIMMER_DOWNLOAD_PREFIX="$BASE/tampered-archive/v{version}/" "$ROOT/scripts/make-appcast.sh" "$W/archives/Dimmer-1.3.1.dmg" "$W/notes-1.3.1.html" "$W/out-tampered" > "$W/make-appcast-tampered.log" 2>&1 \
    || result fail "make-appcast for the tampered-archive feed"
mkdir -p "$W/www/tampered-archive/v1.3.1"
cp "$W/out-tampered/appcast.xml" "$W/www/tampered-archive/appcast.xml"
cp "$W/archives/Dimmer-1.3.1.dmg" "$W/www/tampered-archive/v1.3.1/"
printf 'x' >> "$W/www/tampered-archive/v1.3.1/Dimmer-1.3.1.dmg"

printf 'not-a-key\n' | SPARKLE_ED_KEY=not-a-key "$ROOT/scripts/make-appcast.sh" "$W/archives/Dimmer-1.3.1.dmg" "$W/notes-1.3.1.html" "$W/out-badkey" > "$W/badkey.log" 2>&1 \
    && result fail "a malformed key must be refused" \
    || { ! grep -q 'not-a-key' "$W/badkey.log" && [ ! -e "$W/out-badkey/appcast.xml" ] \
        && result ok "a malformed key is refused before Sparkle's tools see it, and never echoed" || result fail "malformed key handling"; }
unset SPARKLE_ED_KEY DIMMER_PUBLIC_KEY DIMMER_DOWNLOAD_PREFIX TEST_KEY

# A feed altered after signing; its enclosures still point at the genuine archive, so only the feed
# signature can stop it.
mkdir -p "$W/www/tampered-feed"
sed 's#<title>#<title>Altered #' "$W/www/feed/appcast.xml" > "$W/www/tampered-feed/appcast.xml"

# A static server that also records the headers of each feed request, the evidence for the privacy copy.
cat > "$W/serve.py" <<'PY'
import http.server, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith(".xml"):
            with open(sys.argv[2], "a") as log:
                log.write(self.path + "\n" + "".join(f"  {k}: {v}\n" for k, v in self.headers.items()))
        super().do_GET()
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
(cd "$W/www" && exec python3 -I "$W/serve.py" "$PORT" "$W/feed-headers.log" > "$W/http.log" 2>&1) &
SERVER=$!
for _ in $(seq 50); do curl -fsS "$BASE/feed/appcast.xml" >/dev/null 2>&1 && break; sleep 0.2; done

cli() { "$CLI" "$@" --check-immediately --user-agent-name "Dimmer staging test" --verbose; }

for case in tampered-feed future; do
    variant "$case"
    set +e; cli "$W/$case/Dimmer.app" --feed-url "$BASE/$case/appcast.xml" > "$W/cli-$case.log" 2>&1; status=$?; set -e
    [ "$(version_of "$W/$case/Dimmer.app")" = 1.3.0 ] && [ "$status" -ne 0 -o "$case" = future ] \
        && result ok "$case: no update installed (exit $status), bundle still 1.3.0" || result fail "$case: exit $status, bundle $(version_of "$W/$case/Dimmer.app")"
done

variant tampered-archive
set +e; cli "$W/tampered-archive/Dimmer.app" --feed-url "$BASE/tampered-archive/appcast.xml" > "$W/cli-tampered-archive.log" 2>&1; status=$?; set -e
[ "$(version_of "$W/tampered-archive/Dimmer.app")" = 1.3.0 ] && [ "$status" -ne 0 ] \
    && result ok "tampered archive: refused (exit $status), bundle still 1.3.0" || result fail "tampered archive: exit $status, bundle $(version_of "$W/tampered-archive/Dimmer.app")"

set +e; "$CLI" "$W/old/Dimmer.app" --probe --user-agent-name "Dimmer staging test" --verbose > "$W/cli-probe.log" 2>&1; status=$?; set -e
[ "$status" -eq 0 ] && result ok "probe: 1.3.0 sees 1.3.1 in the signed two-release feed" || result fail "probe exit $status (see $W/cli-probe.log)"

set +e; cli "$W/old/Dimmer.app" > "$W/cli-install.log" 2>&1; status=$?; set -e
NOW="$(version_of "$W/old/Dimmer.app")"
[ "$status" -eq 0 ] && [ "$NOW" = 1.3.1 ] && [ "$(plutil -extract CFBundleVersion raw "$W/old/Dimmer.app/Contents/Info.plist")" = 1301 ] \
    && result ok "install: the 1.3.0 bundle is now 1.3.1 (build 1301)" || result fail "install exit $status, bundle $NOW (see $W/cli-install.log)"
codesign --verify --deep --strict "$W/old/Dimmer.app" 2>/dev/null \
    && result ok "updated bundle passes codesign --verify --deep --strict" || result fail "updated bundle signature"
[ -d "$W/old/Dimmer.app/Contents/Frameworks/Sparkle.framework" ] && result ok "updated bundle still embeds Sparkle.framework" || result fail "Sparkle.framework missing after update"
pgrep -f "$W/.*/Dimmer.app/Contents/MacOS/Dimmer" >/dev/null && result fail "a test Dimmer process is running" || result ok "no Dimmer process was launched"

echo "Headers Sparkle sent for its first feed request:"
awk '/^\//{block = $0 "\n"; next} {block = block $0 "\n"} /User-Agent: .*Sparkle/ {printf "%s", block; exit}' "$W/feed-headers.log"
echo "stage-update-test: $PASS passed, $FAIL failed (logs in $W)"
echo "GUI pass: serve with  cd $W/www && python3 -m http.server $PORT --bind 127.0.0.1  then open $W/gui-1.3.0/Dimmer.app"
echo "(python3 -m http.server serves the same files; serve.py only adds the header log)"
[ "$FAIL" -eq 0 ]
