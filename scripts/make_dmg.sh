#!/bin/zsh
# Builds build/SubFloor-<version>.dmg: the app (scripts/bundle.sh), a styled window, and a signature.
#   VERSION=0.1.0 SIGN_IDENTITY="Developer ID Application: …" scripts/make_dmg.sh
# With NOTARY_PROFILE (a profile saved by `xcrun notarytool store-credentials`), the app and then the
# DMG are notarized by Apple and stapled, so they open without a Gatekeeper prompt, even offline.
# Needs Pillow (python3) and makes a virtual environment with dmgbuild in build/.dmgvenv.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGN_IDENTITY:-}" ]]; then
    echo "NOTARY_PROFILE needs SIGN_IDENTITY (Apple notarizes Developer ID signed code only)" >&2
    exit 1
fi
VERSION="$VERSION" scripts/bundle.sh

# Submits $1 to Apple's notary service and waits; prints the log and fails if it is not accepted.
notarize() {
    local out id
    out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    id=$(print -r -- "$out" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["id"]); sys.exit(d["status"] != "Accepted")') || {
        echo "Notarization of $1 failed:" >&2
        print -r -- "$out" >&2
        [[ -n "${id:-}" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    }
    echo "Notarized $1 ($id)"
}

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    # The app first, so its own ticket travels with it once it is copied out of the DMG.
    ditto -c -k --keepParent build/SubFloor.app build/SubFloor-notarize.zip
    notarize build/SubFloor-notarize.zip
    rm -f build/SubFloor-notarize.zip
    xcrun stapler staple build/SubFloor.app
fi

python3 scripts/dmg/make_background.py build/dmg
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff >/dev/null

# 1.6.7 or later: with 1.6.5 Finder on macOS 26 ignores the background image.
if ! build/.dmgvenv/bin/pip show dmgbuild 2>/dev/null | grep -q "^Version: 1.6.7"; then
    python3 -m venv build/.dmgvenv
    build/.dmgvenv/bin/pip install -q "dmgbuild==1.6.7"
fi

DMG="build/SubFloor-$VERSION.dmg"
rm -f "$DMG"
build/.dmgvenv/bin/dmgbuild -s scripts/dmg/settings.py \
    -D app=build/SubFloor.app -D background=build/dmg/background.tiff \
    -D icon=build/SubFloor.app/Contents/Resources/AppIcon.icns \
    "SubFloor $VERSION" "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 build/SubFloor.app
fi
shasum -a 256 "$DMG"
echo "Built $DMG"
