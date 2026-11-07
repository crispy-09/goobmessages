# Security policy

## Reporting a vulnerability
Please use GitHub's **private vulnerability reporting** (Security tab → *Report a vulnerability*). Do not open a
public issue for security problems, and **never paste cookies, tokens, HAR files or screenshots of conversations**
into issues. We'll acknowledge within a few days.

## What this app stores and where
| Data | Location | Notes |
|---|---|---|
| Google session cookies, tachyon token, pairing keys | macOS Keychain (`WhenUnlockedThisDeviceOnly`) | Never written to disk elsewhere, never synced to iCloud. |
| Messages, contacts, images | Memory only | Nothing is cached to disk. Temporary media for the video/audio player is deleted when the viewer closes. |
| Preferences (`linkPreviews`) | UserDefaults | No personal data. |
| Drafts | Memory only | Lost on quit. |

The app talks only to Google endpoints (`*.google.com`, `*.googleapis.com`, `*.clients6.google.com`, Google-hosted
avatar/media URLs) plus **link-preview fetches for URLs inside messages** (toggle in Settings; https public hosts only,
private/localhost/LAN addresses are refused).

## Threat model & known limits
* Anyone with access to your unlocked Mac user session can use the Keychain item. Sign out (Settings) to unpair.
* The Google login happens in a non-persistent `WKWebView`; cookies are copied out and the web view's store is discarded.
  The app never sees your password.
* Link previews reveal your IP to the linked site (like iMessage). Disable in Settings if that matters.
* The protocol is reverse-engineered; a malicious or compromised phone/Google could send malformed protobuf. Parsing
  is done with swift-protobuf and a bounds-checked pblite reader, but fuzzing is welcome.
* Release builds are ad-hoc signed unless you provide a Developer ID. Verify what you download or build it yourself.
