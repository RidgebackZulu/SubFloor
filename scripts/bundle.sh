#!/bin/zsh
# Builds a release SubFloor.app in ./build (ad-hoc signed, or with SIGN_IDENTITY; see the end).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SubFloor"
APP=build/SubFloor.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SubFloor"

# No library search paths outside the app or the OS. SwiftPM leaves this Mac's Xcode toolchain and
# /usr/local/lib as rpaths; dyld would try the toolchain path first on every user's Mac (absent there,
# and a hijack point, since the app may load libraries from other signers). The SDRplay API is linked
# by the path its installer creates instead.
EXE="$APP/Contents/MacOS/SubFloor"
install_name_tool -change @rpath/libsdrplay_api.so.3 /usr/local/lib/libsdrplay_api.so.3 "$EXE"
for rpath in $(otool -l "$EXE" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }'); do
    case "$rpath" in
        /usr/lib/swift|@*) ;;
        *) install_name_tool -delete_rpath "$rpath" "$EXE" ;;
    esac
done

# App icon: every size iconutil wants, from the 1024 px PNG (redraw it with scripts/make_icon.py).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Sources/SubFloor/Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Sources/SubFloor/Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SubFloor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>app.subfloor.SubFloor</string>
    <key>CFBundleName</key><string>SubFloor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>SubFloor connects to the SubFloor Dial tuning knob over Bluetooth.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc by default. SIGN_IDENTITY="Developer ID Application: …" signs for distribution: hardened
# runtime, a secure timestamp, and the entitlement that lets the SDRplay API load.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements scripts/SubFloor.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
