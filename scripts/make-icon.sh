#!/bin/zsh
# Resources/AppIcon.svg から Resources/AppIcon.icns を作る (Google Chrome のヘッドレス描画を使用)
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome が必要です"; exit 1; }

WORK=$(mktemp -d)
trap 'pkill -f "$WORK/profile" 2>/dev/null; rm -rf "$WORK"' EXIT
cp Resources/AppIcon.svg "$WORK/icon.svg"
cat > "$WORK/icon.html" <<'HTML'
<!doctype html><style>html,body{margin:0;background:transparent}img{display:block;width:1024px;height:1024px}</style><img src="icon.svg">
HTML

"$CHROME" --headless=new --user-data-dir="$WORK/profile" --disable-gpu --hide-scrollbars \
  --default-background-color=00000000 --window-size=1024,1024 --force-device-scale-factor=1 \
  --screenshot="$WORK/1024.png" "file://$WORK/icon.html" >/dev/null 2>&1 &
for _ in {1..60}; do [[ -s "$WORK/1024.png" ]] && break; sleep 0.5; done
sleep 0.5
[[ -s "$WORK/1024.png" ]] || { echo "描画に失敗しました"; exit 1; }

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  px=${spec%%:*}; name=${spec#*:}
  sips -z $px $px "$WORK/1024.png" --out "$SET/icon_$name.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$WORK/1024.png" Resources/AppIcon-1024.png
echo "✓ Resources/AppIcon.icns"
