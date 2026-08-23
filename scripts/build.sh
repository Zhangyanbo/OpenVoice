#!/bin/bash
# OpenVoice 标准构建流程:xcodegen → Release 构建 → 打包 DMG
# 产物:
#   build/Build/Products/Release/OpenVoice.app
#   dist/OpenVoice.dmg(拖进应用程序的安装窗口)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"   # dmgbuild(uv tool install dmgbuild)

xcodegen --quiet

xcodebuild -project OpenVoice.xcodeproj -scheme OpenVoice \
  -configuration Release -derivedDataPath build -quiet build

APP="build/Build/Products/Release/OpenVoice.app"
[ -d "$APP" ] || { echo "构建产物不存在:$APP" >&2; exit 1; }

mkdir -p dist
rm -f dist/OpenVoice.dmg
dmgbuild -s scripts/dmg_settings.py -D app="$APP" "OpenVoice" dist/OpenVoice.dmg

echo "✓ $APP"
echo "✓ dist/OpenVoice.dmg"
