# Notices & attribution

## Upstream work
The protocol implementation in this project is a **Swift port of [`libgm`](https://github.com/mautrix/gmessages)**
(part of *mautrix-gmessages*, © Tulir Asokan and contributors, licensed **AGPL-3.0-or-later**). That includes the
`.proto` message definitions in `Protos/`, the pairing / UKEY2 handshake, request signing and encryption scheme,
long-poll framing, and the pblite format rules. Because this is a derivative work, **this repository is licensed
under the GNU AGPL v3** (see `LICENSE`). The upstream "special exceptions" in `LICENSE.exceptions` apply only to the
named parties and do not extend to this project.

Also used: [`go.mau.fi/util/pblite`](https://github.com/mautrix/go-util) (pblite encoding rules, MPL-2.0 reference)
and [swift-protobuf](https://github.com/apple/swift-protobuf) (Apache-2.0).

## The API key in `GMConstants`
`GMConstants.apiKey` is the **public key embedded in Google's own Messages-for-web JavaScript client** and is
reproduced in libgm. It identifies the web client, is not a secret, and is not tied to any person or account.

## Trademarks / affiliation
"Google Messages", "Android", "iMessage" and "Messages" are trademarks of their respective owners. This is an
unofficial, independent project, not affiliated with or endorsed by Google or Apple. The UI imitates a familiar
chat style for usability only and uses no Apple assets. It relies on an undocumented Google service that may change
or be restricted at any time; use it only with your own account.
