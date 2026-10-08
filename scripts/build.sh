#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release
APP="$(pwd)/dist/Scheduler.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build/AppIcon.iconset
cp .build/release/Dayleaf "$APP/Contents/MacOS/Scheduler"
# 命令行工具 sched：放在应用包里，安装脚本再链接到 ~/.local/bin；应用内终端也会把这个目录加进 PATH。
mkdir -p "$APP/Contents/Resources/bin"
cp .build/release/sched "$APP/Contents/Resources/bin/sched"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift .build/icon.png
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" .build/icon.png --out ".build/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" .build/icon.png --out ".build/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
swift scripts/pack-icons.swift .build/AppIcon.iconset "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "构建完成：$APP"
