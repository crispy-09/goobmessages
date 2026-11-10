# AGENTS.md — guide for AI coding agents and human contributors

Native SwiftUI macOS client for **Google Messages** (Android SMS/RCS), styled like Apple Messages. It speaks the
reverse-engineered *Messages for web* protocol directly (no web view for chat). The protocol is a Swift port of
[mautrix `libgm`](https://github.com/mautrix/gmessages/tree/main/pkg/libgm) — **when behavior is unclear, read the Go
source there; do not guess**. Project is AGPL-3.0 (derivative of libgm). See `docs/PROTOCOL.md`.

## Setup / commands
```
brew install protobuf swift-protobuf && pip3 install grpcio-tools pillow
./generate.sh              # REQUIRED first: regenerates Protos-Swift/, *.pb.swift, PBLiteSchema.swift
swift build                # or open Package.swift in Xcode (⌘R). Xcode runs a bare executable (no notifications).
swift test                 # PBLite + crypto + link-safety tests; must pass
./scripts/make_app.sh      # real .app (universal, icon, notifications work). ./scripts/make_dmg.sh for a DMG
python3 tools/make_icon.py # regenerate Resources/AppIcon.*
```
There is no CI-accessible Google account: **network/protocol code cannot be integration-tested automatically.**
Unit-test everything pure (codecs, crypto, parsing). Never commit real cookies, tokens, HARs or message content.

## Layout
```
Protos/                 original .proto files from libgm (+ vendor/pblite.proto for the custom option)
Protos-Swift/           GENERATED (gitignored): same protos with pblite option stripped, for protoc-gen-swift
tools/gen_schema.py     protos -> Generated/PBLiteSchema.swift (field kinds/numbers/"binary" flag) + Protos-Swift/
Sources/GMessagesMac/
  Generated/            PBLiteSchema.swift, PairingEmojis.swift (committed); *.pb.swift (gitignored)
  Protocol/             NO SwiftUI here
    PBLite.swift        pblite JSON-array <-> protobuf wire codec, schema-driven
    Crypto.swift        AES-CTR+HMAC (requests), chunked AES-GCM (media), HKDF, ECDSA, SAPISIDHASH
    AuthData.swift      persisted session + Keychain wrapper
    GMClient.swift      actor: HTTP, token refresh, RPC send/wait, ack loop, long-poll stream, update dispatch
    GMClient+Pairing.swift  Google-account pairing: SignInGaia, UKEY2 handshake, emoji confirmation
    GMClient+API.swift  typed methods: conversations, messages, reactions, contacts, thumbnails, media
    Types.swift         typealiases, RPC enum raw-value constants, endpoints, config version/UA
  Model/
    AppModel.swift      @MainActor store + actions; connection supervision (sleep/wake/network); request batching
    Models.swift        view-model structs (MessageVM, ConversationVM, …)
    Notifications.swift NotificationPlanner (pure, tested) + NotificationCoordinator (buffering, posting, actions)
    Preferences.swift   Prefs keys/defaults (UserDefaults) + LoginItem (SMAppService)
    Attachments.swift   OutgoingAttachment + AttachmentPrep (MIME normalisation, HEIC→JPEG, size cap)
    Audio.swift         VoiceRecorder (AAC .m4a, audio/mp4) + AudioPlayback (in-memory AVAudioPlayer)
  UI/                   SwiftUI views (RootView, MainView/sidebar, ChatView, bubbles, composer, viewers, settings)
Tests/GMessagesMacTests/
```
Data flow: `GMClient.events` (AsyncStream<GMEvent>) → `AppModel.handle` → `@Published` state → views.
Views never call `GMClient` directly; go through `AppModel`.

## Hard-won gotchas (read before editing protocol code)
1. **swift-protobuf property naming flattens acronyms.** Field `destOrSourceUUID` → `destOrSourceUuid`,
   `participantIDs` → `participantIds`, `SIMPayload` → `simpayload`, `createRCSGroup` → `createRcsgroup`,
   but a bare `ID` suffix stays `ID` (`conversationID`). A nested enum/message named `Type` becomes `TypeEnum`.
   Rule source: `SwiftProtobufPluginLibrary/NamingUtils.swift` (CamelCaser). When a name doesn't compile, check there.
2. **Enums are referenced by raw value** via `RPCAction`/`RPCMessageType` in `Types.swift` so naming surprises are
   fixed in one place. Add new actions there (numbers from `Protos/rpc.proto`).
3. **pblite ≠ protobuf JSON.** Field N at index N-1, bytes base64, nested messages nested arrays, `null` for unset,
   array padded to the max field number. Fields tagged `(pblite.pblite_binary)` are base64 of the raw bytes
   (strings/messages). `PBLite.swift` converts via wire format using `PBLiteSchema`; it does not use reflection.
   After editing `.proto` files run `./generate.sh`; CI fails if `PBLiteSchema.swift` is stale.
4. **Long-poll body framing:** `[[` then comma-separated complete pblite elements then `]]`. Parsed with a bracket-depth
   state machine over `URLSession.AsyncBytes` (strings/escapes aware), see `GMClient.readStream`.
5. **Requests carry cookies + `Authorization: SAPISIDHASH ts_sha1`** and a tachyon token in the payload; RPC payloads
   are AES-CTR+HMAC encrypted with keys derived during pairing. Upload/download media requests send **no cookies**.
6. **Optimistic sends:** local message uses `tmp_…` id with `isLocal = true`; the phone echoes it. Match by id, then tmpID,
   then (isLocal + same text). Delivery state must only move forward (`DeliveryState.rank`) or "Sending…" flickers.
7. Conversation lists contain pinned chats twice → dedupe by id. Group avatars come from `groupAvatarURL`
   (plain GET), not participant thumbnails.
8. `UNUserNotificationCenter` crashes in a bare SwiftPM executable → always guard with `AppEnv.canNotify`.
9. Closing the window must *hide* it (`WindowHider`/`MainWindow`), otherwise SwiftUI destroys it and the Dock icon can't reopen it.
10. SwiftUI's multi-line `TextField` misbehaves on macOS → composer uses `GrowingTextView` (NSTextView). Heights are
   measured from the font, never hardcoded.
11. `GMConstants.configVersion` and the Chrome UA mirror libgm's current values; bump them when libgm does.
12. **Never post one notification per incoming message.** Everything goes through `NotificationCoordinator.enqueue`,
    which debounces, groups per conversation (identifier `conv.<id>` replaces the previous banner) and summarises during
    catch-up. `isOld` from libgm is not enough on its own: after sleep the backlog can arrive as "new". Catch-up is
    begun on launch/sleep/reconnect and ended 4 s after `.connected`; `NotificationPlanner.staleAfter` is the backstop.
    Also skip alerts for updates to already-seen messages (reactions, status changes) via `rememberNotified`/`isLatest`.
13. **Reconnects go through `AppModel.scheduleReconnect`** (debounced, single-flight; `GMClient.reconnect` is also
    single-flight). Disconnect on `willSleep`, reconnect once on `didWake`; ignore network changes while asleep.
    Don't add new reconnect triggers that bypass it, and keep retry loops on `GMClient.backoff` (exponential + jitter).
14. **Rate limits:** batch participant thumbnails (`queueThumbnails`), de-duplicate `getConversation`
    (`fetchingConversations`), debounce `markRead` per conversation, throttle full list refreshes (30 s). Prefer one RPC
    with many IDs over many RPCs.
15. Mic, notifications and login items need a real bundle → guard with `AppEnv.isBundled` / `AppEnv.canNotify`.
    `make_app.sh` adds `NSMicrophoneUsageDescription`; hardened-runtime signing uses `Resources/GoobMessage.entitlements`.

## Conventions
* Swift 5.9, macOS 13+. `GMClient` is an `actor`; UI state is `@MainActor`. No force-unwraps on network data.
* Anything derived from a message sender (URLs, filenames, text) is untrusted: see `LinkPreviewStore.isSafe`, the
  link scheme allow-list in `MessageRow.linkified`, and filename sanitising in `AppModel.saveMedia`.
* Treat all network input as hostile: bounds/overflow-safe parsing, recursion limits (`PBLite.maxDepth`), validated crypto headers,
  attachment size caps, `URLSafety.isPublicHTTPS` for any URL taken from message/conversation data (avatars, link previews;
  web-client headers only go to Google-owned hosts). Add a regression test for each.
* Don't log tokens/cookies/message bodies. Don't add third-party dependencies without discussion.
* Keep UI iMessage-flavoured (blue `Theme.blue` sent bubbles, gray received, tails via `BubbleShape`).
* Add a unit test for every bug found in codecs/crypto (see `Tests/`).

## desktop/ (Linux & Windows client)
Separate Go module (`desktop/go.mod`): Wails v2 app that **imports libgm directly** instead of porting it, so the
protocol notes above (pblite, crypto, long-poll) are libgm's job there. Read `desktop/README.md` first.
* `cd desktop && go test ./... && (cd frontend && npm test)` must pass. Linux builds need WebKitGTK 4.1
  (`wails build -tags webkit2_41`); Windows builds are pure Go (cross-compile with `-platform windows/amd64`).
* Same rules as the Mac app: notifications only via `Notifier.Enqueue` (planner in `internal/model/planner.go`),
  reconnects only via `App.scheduleReconnect`, libgm's event handler must not block (spawn goroutines for RPCs),
  untrusted URLs through `internal/urlsafe`, no message content on disk, never `{@html}` in Svelte.
* Bump `go.mau.fi/mautrix-gmessages` to pick up protocol fixes; keep the CI Wails CLI version equal to `go.mod`'s.

## Ideas / known gaps
Stickers/GIF picker, sending location, scheduled send, server-side full-text search (find only searches loaded
messages), persistent offline cache (deliberately absent: nothing is cached to disk), mute state can't be read back
from the phone (hence local "Hide Alerts"), pin/mute/archive request shapes are untested upstream, multi-account,
localization, Sparkle-style updates, dual-SIM picker.
