#!/bin/bash
# Builds a real, double-clickable "Goob Message.app" (universal: Apple Silicon + Intel).
#   ./scripts/make_app.sh                 # ad-hoc signed (fine for your own Mac)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./scripts/make_app.sh   # real signing
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Goob Message"
BUNDLE_ID="${BUNDLE_ID:-com.example.GMessagesMac}"   # change this if you publish your own build
VERSION="${VERSION:-1.1.0}"
OUT="build/${APP_NAME}.app"

echo "▶ Building (release, universal)…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/GMessagesMac"

echo "▶ Assembling ${OUT}…"
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/GMessagesMac"
if command -v iconutil >/dev/null && [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"   # Apple's own encoder
elif [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>GMessagesMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Goob Message uses the microphone only while you record a voice message.</string>
</dict></plist>
PLIST

echo "▶ Signing…"
if [ -n "${SIGN_ID:-}" ]; then
  # Hardened runtime needs an explicit entitlement for the microphone (voice messages).
  codesign --force --options runtime --timestamp --entitlements Resources/GoobMessage.entitlements --sign "$SIGN_ID" "$OUT"
else
  codesign --force --sign - "$OUT"
fi
codesign --verify --verbose "$OUT" || true

echo "✔ Built: $OUT"
echo "  Run it:      open \"$OUT\""
echo "  Install it:  cp -R \"$OUT\" /Applications/"
