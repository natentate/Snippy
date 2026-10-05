#!/usr/bin/env bash
# Builds Snippy.app and a distributable DMG into ./build
#
# Env vars:
#   VERSION         marketing version (default: contents of VERSION)
#   ARCHS           architectures to build (default: "arm64 x86_64" = universal)
#   SIGN_IDENTITY   codesign identity (default "-" = ad-hoc). Use a "Developer ID Application: …" identity to distribute.
#   NOTARY_PROFILE  optional `xcrun notarytool` keychain profile; when set (with a Developer ID), the DMG is notarized + stapled.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Snippy"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# VERSION file holds major.minor; the build number completes it (e.g. 1.0.42).
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0).$BUILD_NUMBER}"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER) for: $ARCHS"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Generating icon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp \
    --entitlements Resources/Snippy.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --verbose=2 "$APP"

echo "==> Creating DMG"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
STAGING="$OUT/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  echo "==> Notarizing"
  codesign --force --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# Stable name so https://github.com/<repo>/releases/latest/download/Snippy.dmg always works.
cp "$DMG" "$OUT/$APP_NAME.dmg"

echo "==> Done"
echo "    App: $APP"
echo "    DMG: $DMG"
