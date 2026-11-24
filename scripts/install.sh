#!/usr/bin/env bash
# Installs or updates Goob Messages from the latest GitHub release. Run it again any time to update.
#
#   curl -fsSL https://raw.githubusercontent.com/crispy-09/goobmessages/main/scripts/install.sh | bash
#
# macOS 13+:      installs "Goob Message.app" into /Applications (or ~/Applications if that isn't writable).
# Linux x86-64:   installs for the current user, no root: ~/.local/bin/goobmessages, app-menu launcher and icon.
#                 Needs WebKitGTK 4.1 and GStreamer plugins; the bundled install.sh checks for them.
# Windows:        use scripts/install.ps1 instead.
#
# Environment options:
#   GOOB_VERSION=1.2.0   install that release instead of the latest
#   GOOB_FORCE=1         reinstall even if that version is already installed
#   GOOB_NO_LAUNCH=1     don't open the app afterwards (macOS)
#   GOOB_APP_DIR=path    install the .app into this folder instead of /Applications (macOS)
#   GOOB_SKIP_DEPS=1     skip the GStreamer check (Linux)
#   GOOB_GITHUB_TOKEN=…  token for the GitHub API lookup (Linux), only needed if you hit its rate limit
#
# Every download is checked against the release's SHA-256 checksums before anything is installed.
set -euo pipefail

REPO="crispy-09/goobmessages"
GH="https://github.com/$REPO"

TMP=""
cleanup() {
  [ -n "$TMP" ] || return 0
  if [ -d "$TMP/mnt" ]; then hdiutil detach -quiet "$TMP/mnt" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

fetch() { # url dest
  curl -fL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --silent --show-error -o "$2" "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Looks up the expected hash for a file name in a "<hash>  <path>" checksum list (path may have a directory or '*').
expected_sha() { # checksum-file asset-name
  awk -v f="$2" '{ n=$2; sub(/^\*/, "", n); sub(/.*\//, "", n); if (n == f) { print $1; exit } }' "$1"
}

verify() { # tag dir asset-name
  local tag="$1" dir="$2" name="$3" sums="$2/checksums.txt" want got
  if fetch "$GH/releases/download/$tag/SHA256SUMS.txt" "$sums" 2>/dev/null; then :
  elif fetch "$GH/releases/download/$tag/$name.sha256" "$sums" 2>/dev/null; then :   # releases before 1.2.0
  else fail "release $tag has no checksums; not installing an unverified download"; fi
  want=$(expected_sha "$sums" "$name")
  [ -n "$want" ] || fail "no checksum for $name in release $tag"
  got=$(sha256_of "$dir/$name")
  [ "$(echo "$want" | tr 'A-F' 'a-f')" = "$got" ] || fail "checksum mismatch for $name (expected $want, got $got)"
  say "Checksum OK"
}

# ---------------------------------------------------------------- macOS

install_mac() {
  local major app_name="Goob Message.app" tag version tmp dest d current was_running=0
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 13 ] || fail "Goob Message needs macOS 13 or newer (this Mac has $(sw_vers -productVersion))"

  if [ -n "${GOOB_VERSION:-}" ]; then
    tag="v${GOOB_VERSION#v}"
  else
    # The Mac app owns GitHub's "latest" release; Linux/Windows releases are published with --latest=false.
    tag=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "$GH/releases/latest" | sed 's|.*/tag/||')
    [[ "$tag" =~ ^v[0-9] ]] || fail "couldn't find the latest Mac release (got '$tag')"
  fi
  version="${tag#v}"

  if [ -n "${GOOB_APP_DIR:-}" ]; then
    dest="$GOOB_APP_DIR"; mkdir -p "$dest"
  else
    dest="/Applications"
    if [ ! -w "$dest" ]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
    for d in /Applications "$HOME/Applications"; do   # update in place wherever it's already installed
      if [ -d "$d/$app_name" ]; then dest="$d"; break; fi
    done
  fi
  current=$(defaults read "$dest/$app_name/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
  if [ "$current" = "$version" ] && [ "${GOOB_FORCE:-}" != 1 ]; then
    say "Goob Message $version is already installed and up to date ($dest/$app_name)."
    return 0
  fi
  if [ -n "$current" ]; then say "Updating Goob Message $current -> $version"; else say "Installing Goob Message $version"; fi

  TMP=$(mktemp -d); tmp="$TMP"
  say "Downloading $tag"
  fetch "$GH/releases/download/$tag/GoobMessage.dmg" "$tmp/GoobMessage.dmg"
  verify "$tag" "$tmp" "GoobMessage.dmg"

  mkdir "$tmp/mnt"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$tmp/GoobMessage.dmg" </dev/null
  [ -d "$tmp/mnt/$app_name" ] || fail "the disk image doesn't contain $app_name"
  ditto "$tmp/mnt/$app_name" "$tmp/$app_name"
  hdiutil detach -quiet "$tmp/mnt" || true

  # Only the copy being replaced (another copy elsewhere, e.g. a beta build, keeps running).
  local exe_dir="$dest/$app_name/Contents/MacOS/"
  if pgrep -f "$exe_dir" >/dev/null; then
    was_running=1
    say "Quitting the running app"
    osascript -e "tell application \"$dest/$app_name\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -f "$exe_dir" >/dev/null || break; sleep 0.5; done
    pkill -f "$exe_dir" 2>/dev/null || true
  fi

  rm -rf "$dest/$app_name"
  mv "$tmp/$app_name" "$dest/$app_name"
  xattr -dr com.apple.quarantine "$dest/$app_name" 2>/dev/null || true
  say "Installed $dest/$app_name"

  if [ "${GOOB_NO_LAUNCH:-}" != 1 ] && { [ "$was_running" = 1 ] || [ -z "$current" ]; }; then
    open "$dest/$app_name"
  fi
  [ -n "$current" ] || echo "Sign in with the Google account Google Messages uses on your phone, then tap the emoji shown."
}

# ---------------------------------------------------------------- Linux

install_linux() {
  local version tag name tmp marker current
  [ "$(uname -m)" = "x86_64" ] || fail "prebuilt Linux releases are x86-64 only; build from source on $(uname -m) (see desktop/README.md)"

  if [ -n "${GOOB_VERSION:-}" ]; then
    version="${GOOB_VERSION#desktop-v}"; version="${version#v}"
  else
    # Newest stable desktop release (pre-releases have a suffix like -beta.1 and are skipped).
    local auth=()
    if [ -n "${GOOB_GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GOOB_GITHUB_TOKEN"); fi
    version=$(curl -fsSL --proto '=https' -H 'Accept: application/vnd.github+json' ${auth[@]+"${auth[@]}"} \
                "https://api.github.com/repos/$REPO/releases?per_page=50" \
              | grep -oE '"tag_name": *"desktop-v[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [ -n "$version" ] || fail "couldn't find the latest Linux release (GitHub API unreachable or rate-limited?)"
  fi
  tag="desktop-v$version"

  marker="${XDG_DATA_HOME:-$HOME/.local/share}/goobmessages/installed-version"
  current=$(cat "$marker" 2>/dev/null || true)
  if [ "$current" = "$version" ] && [ -x "$HOME/.local/bin/goobmessages" ] && [ "${GOOB_FORCE:-}" != 1 ]; then
    say "Goob Messages $version is already installed and up to date."
    return 0
  fi
  if [ -n "$current" ]; then say "Updating Goob Messages $current -> $version"; else say "Installing Goob Messages $version"; fi

  name="goobmessages-$version-linux-amd64"
  TMP=$(mktemp -d); tmp="$TMP"
  say "Downloading $tag"
  fetch "$GH/releases/download/$tag/$name.tar.gz" "$tmp/$name.tar.gz"
  verify "$tag" "$tmp" "$name.tar.gz"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
  [ -f "$tmp/$name/install.sh" ] || fail "the release archive has no install.sh"

  bash "$tmp/$name/install.sh" </dev/null
  mkdir -p "$(dirname "$marker")"
  echo "$version" > "$marker"
  if pgrep -x goobmessages >/dev/null; then
    say "Goob Messages is running: quit it (tray icon -> Quit) and open it again to use $version."
  fi
}

main() {
  case "$(uname -s)" in
    Darwin) install_mac ;;
    Linux)  install_linux ;;
    *)      fail "unsupported system $(uname -s). On Windows run in PowerShell: irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex" ;;
  esac
}

# Everything is inside functions, so a partially downloaded script (curl | bash) can't run half an install.
main "$@"
