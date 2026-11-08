# Changelog

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
