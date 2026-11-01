#!/bin/bash
# 编译并打包成可双击运行的 .app
#
# 只出 Apple Silicon（arm64）的包。真要在 Intel 机器上用，可以自己编：
#   ARCHS=x86_64 ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="FudanVPN.app"
BIN="FudanVPN"
ARCHS=${ARCHS:-arm64}
# 绝对路径：下面 `go build -C engine` 会在 engine/ 里执行，相对路径会落错地方
TMP="$PWD/build/tmp"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

SOURCES=(
  Sources/main.swift
  Sources/AppDelegate.swift
  Sources/MainViewController.swift
  Sources/StatusIcon.swift
  Sources/ActionButton.swift
  Sources/LoginWebController.swift
  Sources/TunnelManager.swift
  Sources/SystemProxy.swift
  Sources/LocalPorts.swift
)

/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

echo "[1/4] 编译 Swift 源码（${ARCHS}）…"
SLICES=()
for arch in $ARCHS; do
  printf '  %-8s' "$arch"
  swiftc -O -target "$arch-apple-macos13.0" -framework Security \
    "${SOURCES[@]}" -o "$TMP/$BIN-$arch"
  SLICES+=("$TMP/$BIN-$arch")
  echo "ok"
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$BIN"

echo "[2/4] 编译引擎（${VERSION}）…"
# 引擎是纯 Go（CGO_ENABLED=0），交叉编译不挑机器，两个切片拼成通用二进制。
# 没有 go 就退回仓库里预编译的那一份，保证 build.sh 在只装 Xcode 的机器上也能跑通。
ENGINE_SLICES=()
for arch in $ARCHS; do
  goarch=$arch
  [ "$arch" = "x86_64" ] && goarch=amd64
  printf '  %-8s' "$goarch"
  if CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch \
      go build -C engine -trimpath \
      -ldflags "-s -w -X main.zjuConnectVersion=$VERSION" \
      -o "$TMP/fudan-connect-$goarch" . 2>/dev/null; then
    echo "ok"
    ENGINE_SLICES+=("$TMP/fudan-connect-$goarch")
  else
    echo "跳过（没有 go）"
    ENGINE_SLICES=()
    break
  fi
done
if [ ${#ENGINE_SLICES[@]} -gt 0 ]; then
  lipo -create "${ENGINE_SLICES[@]}" -output "$APP/Contents/Resources/fudan-connect"
  echo "  已内嵌新编译的引擎"
else
  cp Resources/fudan-connect "$APP/Contents/Resources/fudan-connect"
  echo "  用仓库自带的引擎（版本可能不是 ${VERSION}）"
fi
chmod +x "$APP/Contents/Resources/fudan-connect"

echo "[3/4] 拷贝资源…"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 默认分流规则与引擎共用同一份源文件
cp engine/router/default_rules.conf "$APP/Contents/Resources/rules.conf"
if [ -f Resources/FudanVPN.icns ]; then
  cp Resources/FudanVPN.icns "$APP/Contents/Resources/FudanVPN.icns"
else
  echo "  (缺少 Resources/FudanVPN.icns，先跑 swift Tools/make_icon.swift)"
fi

echo "[4/4] Ad-hoc 签名…"
# 先签嵌套的引擎，再签外层，顺序反了 codesign 会报 sealed resource 不匹配
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/fudan-connect" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || echo "  (签名跳过，本地运行不影响)"

echo "完成 $VERSION"
du -sh "$APP"
lipo -archs "$APP/Contents/MacOS/$BIN" | sed 's/^/架构: /'
echo "产物: $PWD/$APP"
