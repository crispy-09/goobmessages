# Protocol notes (Messages for web)

Summary of what `Sources/GMessagesMac/Protocol` implements. Ground truth: libgm (Go).

## Auth & pairing (Google account)
1. User signs in at accounts.google.com in a throwaway WKWebView; cookies for `*.google.com` (SAPISID, SID, …) are captured.
2. `GET messages.google.com/web/config` → `deviceInfo.deviceID` (UUID) becomes the session id.
3. `POST …/Registration/SignInGaia` (pblite) with an ECDSA P-256 public key → tachyon auth token + the account's phones.
4. Open the long-poll stream, then send UKEY2 `ClientInit` (RPC `CREATE_GAIA_PAIRING_CLIENT_INIT`, unencrypted, TTL 300 s).
   Phone replies `ServerInit`; both sides derive `authNumber` → an **emoji** the user must tap on the phone.
5. Send `ClientFinished`; on success derive AES/HMAC keys with HKDF (version 0 or 1 ordering) → `AESCTRHelper`.
6. Tokens refresh via `RegisterRefresh`, signed with the ECDSA key over `"<requestID>:<timestampMicros>"`.

## Transport
* `ReceiveMessages` long-poll (`[[ elem, … ]]` stream). Elements: `data` (an RPC), `ack` (how many old messages to skip),
  `startRead`, heartbeat.
* `SendMessage` posts an `OutgoingRPCMessage`; the response arrives later on the stream, matched by `sessionID == requestID`.
* `AckMessages` is batched every 5 s. `GET_UPDATES` with a fresh session id marks this client the *active* session.
* A `NOTIFY_DITTO_ACTIVITY` ping every 60 s detects an unresponsive phone.

## Payloads
Bodies are encrypted `AES-256-CTR` with `ciphertext ‖ iv ‖ HMAC-SHA256`. Media uses chunked AES-256-GCM
(`[0x00, log2(chunk)] ‖ (nonce12 ‖ ct ‖ tag16)*`, AAD = last-flag ‖ BE32 chunk index). Media upload is a Google resumable
upload (`x-goog-upload-*` headers); download passes a base64 `DownloadAttachmentRequest` in `x-goog-download-metadata`.
