#!/bin/zsh
# Kanade.app をビルドする
#   ./scripts/build.sh            → ./Kanade.app
#   ./scripts/build.sh --install  → /Applications にもコピー
#   ./scripts/build.sh --dev      → ./Kanade Dev.app (設定・キューを本番と分けた確認用)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f Resources/AppIcon.icns ]] || ./scripts/make-icon.sh

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Kanade"

APP=Kanade.app
[[ "${1:-}" == "--dev" ]] && APP="Kanade Dev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kanade"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[[ -d Resources/Skins ]] && cp -R Resources/Skins "$APP/Contents/Resources/"
if [[ "${1:-}" == "--dev" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.kanade.player.dev" -c "Set :CFBundleName Kanade Dev" -c "Set :CFBundleDisplayName Kanade Dev" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP" >/dev/null
echo "✓ $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "✓ /Applications/$APP"
fi
