# Contributing

1. `brew install protobuf swift-protobuf && pip3 install grpcio-tools pillow`
2. `./generate.sh` (generates protobuf Swift + the pblite schema) then `swift build` / open `Package.swift` in Xcode.
3. `swift test` must pass. Add tests for protocol/crypto/parsing changes.
4. Read **AGENTS.md** (architecture, protocol gotchas, conventions) before large changes.

Rules of thumb: no secrets or personal data in commits, screenshots or logs; keep UI changes in `UI/`, protocol
changes in `Protocol/`; prefer small PRs. Use a no-reply git email (`git config user.email "<id>+<name>@users.noreply.github.com"`).

By contributing you agree your work is licensed under AGPL-3.0-or-later (see NOTICE.md).
