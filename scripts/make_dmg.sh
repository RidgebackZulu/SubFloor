#!/bin/zsh
# Builds build/SubFloor-<version>.dmg: the app (scripts/bundle.sh), a styled window, and a signature.
#   VERSION=0.1.0 SIGN_IDENTITY="Developer ID Application: …" scripts/make_dmg.sh
# Needs Pillow (python3) and makes a virtual environment with dmgbuild in build/.dmgvenv.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
VERSION="$VERSION" scripts/bundle.sh

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
shasum -a 256 "$DMG"
echo "Built $DMG"
