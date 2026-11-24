# Changelog

## 1.2.0
### Added
- **Run in the background:** Settings → General → *Show in Dock*: Always, Only while a window is open, or Never; plus
  *Start in background* (connects and notifies at launch without opening the window). The app keeps running after you
  close the window; ⌘Q quits.
- **Menu bar icon opens the app** with one click; right-click (or ⌃-click) for unread chats, New Message, Settings, Quit.
- **One-command install/update** for macOS, Linux and Windows (`scripts/install.sh`, `scripts/install.ps1`), and an
  automated Mac release workflow.
- New app icon matching the menu bar glyph.

### Fixed
- **"Connection problem" banner that never went away:** it was only cleared by a full reconnect, not when the
  connection recovered by itself. It now clears on recovery (libgm `ListenRecovered`), missed updates are requested after
  a gap of more than a minute, and both connection banners can be dismissed. The banner no longer covers the sidebar.
- **Notification spam while everything loads:** backlog that keeps trickling in after a reconnect is held until it has
  been quiet for a few seconds and summarised (never held more than 45 s), late old messages are batched too, and chats
  the phone already reports as read don't alert. Connection errors now start a catch-up window.
- No per-conversation lookups for unknown chats before the first conversation list has loaded.

## 1.1.0
### Fixed
- **Notification flood after sleep.** Messages delivered in a burst when the Mac wakes (or after any reconnect) are now
  combined: one notification per conversation, or a single summary when several conversations are involved, with one
  sound at most. A newer alert for a conversation replaces the older banner instead of stacking.
- Reactions or status updates on an older message no longer re-notify or move the conversation to the top.
- **Reconnect storms / rate limiting:** wake and network-change signals now collapse into one debounced reconnect; the
  stream is closed cleanly before sleep; retries use exponential backoff with jitter; a dead phone no longer restarts the
  stream every minute.
- Reconnecting while offline (e.g. right after wake) no longer leaves the app silently disconnected.
- Fewer requests: contact photos are fetched in batches, unknown-conversation lookups are de-duplicated, mark-as-read is
  debounced, and the conversation list is re-synced once after a reconnect (so read state from your phone catches up).
- Sending an attachment no longer leaves a duplicate "Sending…" copy, and failed attachments are kept for Try Again.
- MIME types now match libgm's table (e.g. `audio/mpeg` was mapped to MP3).

### Added
- Reply and Mark as Read directly from notifications.
- Per-conversation **Hide Alerts** (bell in the chat header or right-click), plus notification preview/sound settings.
- **Voice messages:** record with the mic button; inline audio player with waveform for received audio.
- **Find in conversation** (⌥⌘F) with match count and next/previous.
- Optional **menu bar icon** with unread conversations; **Open at Login**; **Send with Return** toggle.
- Share… for attachments; local previews of attachments while they upload; HEIC/TIFF/WebP images converted to JPEG.
- Delete-conversation confirmation, offline banner, "Mark All as Read".
- Tabbed Settings window (General / Notifications / Account).

## 1.0.0
- First release.
