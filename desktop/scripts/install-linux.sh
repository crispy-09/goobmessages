#!/usr/bin/env bash
# Builds the Linux binary and installs it for the current user (no root needed):
#   ~/.local/bin/goobmessages, a .desktop launcher, and the app icon.
# Requires: Go, Node/npm, the Wails CLI, WebKitGTK 4.1 (Arch: webkit2gtk-4.1, Debian/Ubuntu: libwebkit2gtk-4.1-dev)
# and GStreamer's base, good and libav plugins (Arch: gst-plugins-base gst-plugins-good gst-libav).
set -euo pipefail
cd "$(dirname "$0")/.."

# WebKitGTK aborts the whole page when it can't build a media player, so a chat with a video or voice message would
# crash the window. Check for the GStreamer plugins it needs before installing. GOOB_SKIP_DEPS=1 skips this.
check_gstreamer() {
  [ "${GOOB_SKIP_DEPS:-}" = 1 ] && return 0
  local cmd ids
  ids=$(. /etc/os-release 2>/dev/null; echo " ${ID:-} ${ID_LIKE:-} ") # subshell: don't clobber VERSION etc.
  case "$ids" in
    *" arch "*) cmd="sudo pacman -S --needed gst-plugins-base gst-plugins-good gst-libav" ;;
    *" debian "*|*" ubuntu "*) cmd="sudo apt install gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav" ;;
    *" fedora "*|*" rhel "*) cmd="sudo dnf install gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugin-libav" ;;
    *) cmd="install GStreamer's base, good and libav plugins with your package manager" ;;
  esac
  if ! command -v gst-inspect-1.0 >/dev/null; then
    echo "Note: couldn't check for GStreamer plugins (gst-inspect-1.0 not found). If videos or voice messages crash"
    echo "the window, run: $cmd"
    return 0
  fi
  local missing=()
  for e in playbin appsink autoaudiosink autovideosink qtdemux avdec_h264 avdec_aac; do
    gst-inspect-1.0 --exists "$e" 2>/dev/null || missing+=("$e")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing GStreamer plugins: ${missing[*]}" >&2
    echo "Without them the window crashes on chats with video or voice messages. Install them with:" >&2
    echo "  $cmd" >&2
    echo "then run this again (or set GOOB_SKIP_DEPS=1 to install anyway)." >&2
    exit 1
  fi
}
check_gstreamer

WAILS="${WAILS:-$(command -v wails || echo "$HOME/go/bin/wails")}"
"$WAILS" build -tags webkit2_41 -trimpath -clean
install -Dm755 build/bin/goobmessages "$HOME/.local/bin/goobmessages"
# Absolute Exec path: launchers started by the compositor (Hyprland, Quickshell/Caelestia, …) often don't have
# ~/.local/bin on their PATH.
mkdir -p "$HOME/.local/share/applications"
sed "s|^Exec=goobmessages|Exec=$HOME/.local/bin/goobmessages|" build/linux/goobmessages.desktop \
  > "$HOME/.local/share/applications/goobmessages.desktop"
chmod 644 "$HOME/.local/share/applications/goobmessages.desktop"
install -Dm644 build/appicon.png "$HOME/.local/share/icons/hicolor/512x512/apps/goobmessages.png"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
echo "Installed. Launch \"Goob Messages\" from your app menu, or run: goobmessages"
echo "To start it in the tray at login, run on startup: $HOME/.local/bin/goobmessages --hidden"
