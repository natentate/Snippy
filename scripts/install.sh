#!/usr/bin/env bash
# Installs (or updates) the latest Snippy release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/natentate/Snippy/main/scripts/install.sh | bash
#
# Downloading with curl doesn't set the quarantine flag, so Gatekeeper won't block the app.
set -euo pipefail

REPO="natentate/Snippy"
URL="https://github.com/$REPO/releases/latest/download/Snippy.dmg"
DEST="/Applications/Snippy.app"
TMP="$(mktemp -d)"
MOUNT="$TMP/mnt"
trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

echo "==> Downloading $URL"
curl -fL --progress-bar -o "$TMP/Snippy.dmg" "$URL"

echo "==> Mounting"
mkdir -p "$MOUNT"
hdiutil attach "$TMP/Snippy.dmg" -mountpoint "$MOUNT" -nobrowse -quiet

if pgrep -xq Snippy; then
  echo "==> Quitting running Snippy"
  osascript -e 'tell application id "com.natentate.snippy" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xq Snippy || break; sleep 0.25; done
  pkill -x Snippy || true
fi

echo "==> Installing to $DEST"
SUDO=""
[[ -w /Applications ]] || SUDO="sudo"
$SUDO rm -rf "$DEST"
$SUDO ditto "$MOUNT/Snippy.app" "$DEST"
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

VERSION="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "==> Installed Snippy $VERSION"
open "$DEST"
