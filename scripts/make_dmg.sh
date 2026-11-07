#!/bin/bash
# Packages the built .app into a drag-to-Applications disk image: build/GoobMessage.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Goob Message.app"
[ -d "$APP" ] || ./scripts/make_app.sh
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f build/GoobMessage.dmg
hdiutil create -volname "Goob Message" -srcfolder "$STAGE" -ov -format UDZO build/GoobMessage.dmg
rm -rf "$STAGE"
echo "✔ build/GoobMessage.dmg"
