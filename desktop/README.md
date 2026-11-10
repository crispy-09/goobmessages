# Goob Messages for Linux & Windows

A desktop client for **Google Messages** (SMS/RCS from your Android phone), styled like Apple Messages, the
sibling of the macOS app in this repo.

Unlike the Mac app, which ports the protocol to Swift, this one **imports [mautrix `libgm`](https://github.com/mautrix/gmessages/tree/main/pkg/libgm)
directly** (Go) and draws its UI with [Wails](https://wails.io) (system WebView: WebKitGTK on Linux, WebView2 on
Windows). Protocol fixes come from upstream by bumping one dependency.

> Unofficial. Uses an undocumented API that Google can change at any time. See `../NOTICE.md`. AGPL-3.0.

## Features
- **Sign in with Google**: Google's own sign-in page opens in a separate native window (WebView2 / WebKitGTK, throwaway
  profile), then you confirm on your phone by tapping the emoji shown in the app. (Google no longer offers QR pairing.)
- Inbox and archive, unread dots, pinned chats, group chats (group icon or member-photo collage), search,
  archive / unarchive / delete a chat (right-click it), new conversation from your phone's contacts or by number(s).
- **Find in conversation** (Ctrl+Shift+F) across the loaded messages, jumping to each match.
- Send & receive text, replies (click a reply to jump to the original), reactions (right-click a message), delete,
  copy, typing indicators, Delivered / Read, big-emoji messages, safe clickable links (http(s)/mailto/tel, and bare
  domains like example.com). Right-click → **+** for more reaction emoji.
- **Link previews** like the Mac app (from saved contacts by default; Settings → Link previews). Fetched by the Go
  side with no cookies, https only, public addresses only (checked at connect time, so DNS can't point it at your
  LAN), size caps, and raster images only (dimensions checked before display).
- Photos, video, audio and files: view, play, save. Attach with the paperclip, drag and drop files, or paste images.
- **Native notifications** (D-Bus on Linux, toasts on Windows): one per conversation instead of one per message, a
  single summary for the backlog after the computer wakes, reply / mark-as-read actions where the desktop supports
  them, per-chat **Hide Alerts** (right-click a chat), preview toggle.
- **System tray icon** (StatusNotifierItem on Linux, e.g. Caelestia/Waybar/KDE; notification area on Windows) with an
  unread badge and Open / Quit; closing the window keeps the app running there. `goobmessages --hidden` starts it in
  the tray (for login autostart).
- Reconnects after sleep, unread count in the window title,
  light/dark mode, shortcuts: Ctrl+N new, Ctrl+F search, Ctrl+Shift+F find in chat, ↑/↓ in the chat list,
  Ctrl+, settings, Ctrl+Q quit.

## Install / build

You need Go ≥ 1.26, Node ≥ 20 and the Wails CLI:
```bash
go install github.com/wailsapp/wails/v2/cmd/wails@v2.17.1
```

### Linux
Install WebKitGTK 4.1 first:
```bash
sudo pacman -S --needed webkit2gtk-4.1 gtk3              # Arch
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev       # Debian / Ubuntu
sudo dnf install webkit2gtk4.1-devel gtk3-devel           # Fedora
```
Then build and install for your user (binary in `~/.local/bin`, plus an app-menu launcher and icon):
```bash
cd desktop
./scripts/install-linux.sh
```
Or only build: `wails build -tags webkit2_41` → `build/bin/goobmessages`.

To start it in the tray when you log in, run `~/.local/bin/goobmessages --hidden` at startup, e.g. in Hyprland
(`exec-once = ~/.local/bin/goobmessages --hidden`), or an XDG autostart entry on other desktops.

### Windows
On Windows (WebView2 ships with Windows 10/11):
```powershell
cd desktop
wails build            # -> build\bin\goobmessages.exe
wails build -nsis      # optional installer (needs NSIS)
```
You can also cross-compile the `.exe` from Linux: `wails build -platform windows/amd64`.

### Develop
```bash
cd desktop
wails dev                       # live-reloading app
go test -tags webkit2_41 ./...  # backend tests (CGO_ENABLED=0 go test ./... works without WebKitGTK) (store, notification planner, URL safety, filenames)
cd frontend && npm test         # link parsing tests
npm run dev  # then open http://localhost:5173/?mock to preview the UI with fake data in a browser
```

## Where things are stored
- Session keys (needed to stay paired) and settings: `~/.config/GoobMessages/` on Linux,
  `%AppData%\GoobMessages\` on Windows (owner-only file permissions). **Treat `session.json` like a password.**
- Messages, attachments and avatars are kept **in memory only**; nothing is cached to disk.
- Settings → Unpair this computer removes the pairing from your phone and deletes the session.

## Layout
```
main.go                Wails app options (window, single instance, file drop)
app.go                 App: pairing, connection lifecycle, libgm events, methods bound to the UI
signin*.go             Google sign-in window: WebView2 (Windows), WebKitGTK via cgo (Linux); reads the HttpOnly cookies
notifier.go            notification coordinator (debounce, catch-up summaries, per-chat replacement)
helpers.go             in-memory media LRU, batched avatar loader, MIME / filename helpers
internal/model         view models, Store (merge, read/alert logic), notification Plan (pure, tested)
internal/urlsafe       URL / IP checks for untrusted URLs (avatars, links, previews)
internal/linkpreview   link-card parser (Open Graph, oEmbed) and the guarded fetcher
media.go               attachment download/decrypt, served to the webview from memory at /media/<token>
internal/storage       session + prefs persistence
frontend/              Svelte 5 + Vite UI (src/components, src/lib/state.svelte.js mirrors backend state)
```
Data flow: libgm event → `App.handleEvent` → `model.Store` → Wails event (`conversations`, `messages`, `status`,
`avatar`, `typing`) → `ui` state → components. The UI calls Go methods through `frontend/src/lib/api.js`.

## Known gaps
No voice recording, no dual-SIM
picker. GNOME needs the AppIndicator extension to show tray icons. On Windows a newer
notification for a chat may not replace the previous toast.
