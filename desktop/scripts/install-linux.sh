#!/usr/bin/env bash
# Builds the Linux binary and installs it for the current user (no root needed):
#   ~/.local/bin/goobmessages, a .desktop launcher, and the app icon.
# Requires: Go, Node/npm, the Wails CLI, and WebKitGTK 4.1 (Arch: webkit2gtk-4.1, Debian/Ubuntu: libwebkit2gtk-4.1-dev).
set -euo pipefail
cd "$(dirname "$0")/.."
WAILS="${WAILS:-$(command -v wails || echo "$HOME/go/bin/wails")}"
"$WAILS" build -tags webkit2_41 -trimpath -clean
install -Dm755 build/bin/goobmessages "$HOME/.local/bin/goobmessages"
install -Dm644 build/linux/goobmessages.desktop "$HOME/.local/share/applications/goobmessages.desktop"
install -Dm644 build/appicon.png "$HOME/.local/share/icons/hicolor/512x512/apps/goobmessages.png"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
echo "Installed. Launch \"Goob Messages\" from your app menu, or run: goobmessages"
