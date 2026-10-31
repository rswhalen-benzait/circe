#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
APP_VERSION="${CIRCE_VERSION:-0.1.0}"
BUILD_NUMBER="${CIRCE_BUILD_NUMBER:-1}"
BUNDLE_IDENTIFIER="${CIRCE_BUNDLE_IDENTIFIER:-com.circe.desktop}"
SIGNING_IDENTITY="${CIRCE_SIGNING_IDENTITY:--}"
BUILD_ROOT="$PROJECT_ROOT/build"
mkdir -p "$BUILD_ROOT"

if [[ ! -f Resources/Circe.icns || scripts/generate-icon.swift -nt Resources/Circe.icns ]]; then
    xcrun swift scripts/generate-icon.swift "$PROJECT_ROOT/Resources"
fi

swift build -c release --product Circe
BINARY_DIRECTORY="$(swift build -c release --show-bin-path)"
STAGING_DIRECTORY="$(mktemp -d "$BUILD_ROOT/.circe-bundle.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
APP="$STAGING_DIRECTORY/Circe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIRECTORY/Circe" "$APP/Contents/MacOS/Circe"
cp Resources/Circe.icns "$APP/Contents/Resources/Circe.icns"
# SwiftPM resource bundles are siblings of the executable, when targets use resources.
shopt -s nullglob
for RESOURCE_BUNDLE in "$BINARY_DIRECTORY"/*.bundle; do
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
done
cp Resources/Circe.entitlements "$STAGING_DIRECTORY/Circe.entitlements"

# Write metadata through plistlib rather than interpolating environment values into XML.
/usr/bin/python3 - "$APP/Contents/Info.plist" "$APP_VERSION" "$BUILD_NUMBER" "$BUNDLE_IDENTIFIER" <<'PY'
import plistlib
import sys
metadata = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "Circe",
    "CFBundleExecutable": "Circe",
    "CFBundleIconFile": "Circe.icns",
    "CFBundleIdentifier": sys.argv[4],
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Circe",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": sys.argv[2],
    "CFBundleVersion": sys.argv[3],
    "LSMinimumSystemVersion": "14.0",
    "LSApplicationCategoryType": "public.app-category.productivity",
    "NSHighResolutionCapable": True,
    "NSSupportsAutomaticGraphicsSwitching": True,
    "NSScreenCaptureUsageDescription": "Circe shares this Mac’s screen with computers you pair and allow to connect.",
    "NSAudioCaptureUsageDescription": "Circe shares this Mac’s system audio with computers you pair and allow to connect.",
    "NSMicrophoneUsageDescription": "Circe uses microphone access when you choose to share microphone audio with a paired computer.",
    "NSLocalNetworkUsageDescription": "Circe finds your nearby Macs and connects to computers on your local network.",
    "NSBonjourServices": ["_circe._tcp"],
    "NSPrincipalClass": "NSApplication",
}
with open(sys.argv[1], "wb") as output:
    plistlib.dump(metadata, output, sort_keys=True)
PY
plutil -lint "$APP/Contents/Info.plist" "$STAGING_DIRECTORY/Circe.entitlements"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$STAGING_DIRECTORY/Circe.entitlements" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
# Only replace the previous build after compilation, assembly, and signing all succeed.
if [[ -e "$BUILD_ROOT/Circe.app" ]]; then
    mv "$BUILD_ROOT/Circe.app" "$STAGING_DIRECTORY/Previous-Circe.app"
fi
if ! mv "$APP" "$BUILD_ROOT/Circe.app"; then
    if [[ -e "$STAGING_DIRECTORY/Previous-Circe.app" ]]; then
        mv "$STAGING_DIRECTORY/Previous-Circe.app" "$BUILD_ROOT/Circe.app"
    fi
    exit 1
fi
printf 'Built and signed %s\n' "$BUILD_ROOT/Circe.app"
