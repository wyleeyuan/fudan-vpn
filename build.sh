#!/bin/bash
# 编译并打包成可双击运行的 .app
set -euo pipefail
cd "$(dirname "$0")"

APP="FudanVPN.app"
BIN="FudanVPN"

/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/4] 编译 Swift 源码…"
swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -framework Security \
  Sources/main.swift \
  Sources/AppDelegate.swift \
  Sources/MainViewController.swift \
  Sources/StatusIcon.swift \
  Sources/ActionButton.swift \
  Sources/LoginWebController.swift \
  Sources/TunnelManager.swift \
  Sources/SystemProxy.swift \
  Sources/RoutingRules.swift \
  Sources/SplitProxy.swift \
  -o "$APP/Contents/MacOS/$BIN"

echo "[2/4] 拷贝资源…"
cp Resources/fudan-connect "$APP/Contents/Resources/fudan-connect"
chmod +x "$APP/Contents/Resources/fudan-connect"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/FudanVPN.icns ]; then
  cp Resources/FudanVPN.icns "$APP/Contents/Resources/FudanVPN.icns"
else
  echo "  (缺少 Resources/FudanVPN.icns，先跑 swift Tools/make_icon.swift)"
fi

echo "[3/4] Ad-hoc 签名…"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/fudan-connect" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || echo "  (签名跳过，本地运行不影响)"

echo "[4/4] 完成"
du -sh "$APP"
echo "产物: $PWD/$APP"
