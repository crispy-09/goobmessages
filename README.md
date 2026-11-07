<p align="center"><img src="Resources/icon-1024.png" width="128" alt="icon"></p>

# Goob Message

*(Repo/target name: GMessagesMac.)*

A **native SwiftUI macOS client for Google Messages**, designed to feel like Apple's Messages. It speaks Google's
Messages-for-web protocol directly (a Swift port of [libgm](https://github.com/mautrix/gmessages)) — no embedded web
client for the chat UI. Your phone stays the source of truth; this is a paired "web" session.

> Unofficial. Uses an undocumented API that Google can change at any time. Use with your own account. See `NOTICE.md`.

## Features
Conversations (inbox / archive), unread dots, pinned chats, group chats with group icons · send & receive SMS/RCS ·
replies, reactions (long-press / hover menu), delete, copy · images, video, audio, files (view, play, save; paste,
drag-drop, thumbnails) · link embeds · big-emoji messages · typing & read indicators · drafts · new conversation from
contacts · archive/mute/delete · search · notifications + Dock badge · reconnect on wake/network change ·
shortcuts (⌘N new, ⌘F search, ⌥⌘↑/↓ switch chats, ⌘R reload, ⌘, settings).

## Build & run
```bash
brew install protobuf swift-protobuf
pip3 install grpcio-tools pillow
./generate.sh                 # generates protobuf code + schema (once, and after editing Protos/)
open Package.swift            # Xcode: choose the GMessagesMac scheme, ⌘R
swift test                    # optional
```
**Install as a real app** (icon, notifications, Dock identity):
```bash
./scripts/make_app.sh         # -> build/Goob Message.app (universal)
./scripts/make_dmg.sh         # -> build/GoobMessage.dmg
cp -R "build/Goob Message.app" /Applications/
```
First launch of an ad-hoc-signed app: right-click → **Open** (or run `xattr -dr com.apple.quarantine <app>`).

## First run
Click **Sign in with Google** → sign in with the account on your Android phone → keep Google Messages open on the phone
→ tap the emoji shown on the Mac, on your phone. Credentials live in the macOS Keychain.

## Contributing
See `CONTRIBUTING.md` and **`AGENTS.md`** (architecture, protocol gotchas, conventions — written for AI agents and humans).
Security: `SECURITY.md`. Protocol notes: `docs/PROTOCOL.md`.

## License
AGPL-3.0-or-later (derivative of libgm). See `LICENSE` and `NOTICE.md`.
