#!/usr/bin/env bash
# Installs a downloaded Goob Messages release for the current user (no root, no build tools):
#   ~/.local/bin/goobmessages, an app-menu launcher and the icon. Run it from the extracted release folder.
# Needs WebKitGTK 4.1 at runtime (Arch: webkit2gtk-4.1, Debian/Ubuntu: libwebkit2gtk-4.1-0, Fedora: webkit2gtk4.1).
set -euo pipefail
cd "$(dirname "$0")"
install -Dm755 goobmessages "$HOME/.local/bin/goobmessages"
mkdir -p "$HOME/.local/share/applications"
# Absolute Exec path: launchers started by the compositor often don't have ~/.local/bin on PATH.
sed "s|^Exec=goobmessages|Exec=$HOME/.local/bin/goobmessages|" goobmessages.desktop \
  > "$HOME/.local/share/applications/goobmessages.desktop"
chmod 644 "$HOME/.local/share/applications/goobmessages.desktop"
install -Dm644 goobmessages.png "$HOME/.local/share/icons/hicolor/512x512/apps/goobmessages.png"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
echo "Installed. Launch \"Goob Messages\" from your app menu, or run: $HOME/.local/bin/goobmessages"
echo "To start it in the tray at login, run on startup: $HOME/.local/bin/goobmessages --hidden"
