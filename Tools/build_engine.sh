#!/bin/zsh
# 从 engine/ 编译 fudan-connect。
#
#   ./Tools/build_engine.sh            # 五个目标全编（macOS 双架构、Linux 双架构、Windows）
#   ./Tools/build_engine.sh --local    # 只编当前机器这一份，产物直接给 App 用
#
# 产物落在 build/engine/。App 打包时从那里取当前平台的那一份，
# 复制成 Resources/fudan-connect。

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENGINE="$ROOT/engine"
OUT="$ROOT/build/engine"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "$ROOT/Resources/Info.plist" 2>/dev/null || echo "0.0.0")

if ! command -v go >/dev/null 2>&1; then
    echo "找不到 go，先 brew install go" >&2
    exit 1
fi

mkdir -p "$OUT"

# 纯静态：CGO_ENABLED=0，产物不依赖系统库，直接扔进 App 包里就能跑。
build() {
    local os=$1 arch=$2 suffix=$3
    local name="fudan-connect-$os-$arch$suffix"
    printf '  %-28s' "$os/$arch"
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch \
        go build -C "$ENGINE" -trimpath \
        -ldflags "-s -w -X main.zjuConnectVersion=$VERSION" \
        -o "$OUT/$name" . || { echo "失败"; return 1; }
    printf '%s\n' "$(du -h "$OUT/$name" | cut -f1)"
}

if [[ "$1" == "--local" ]]; then
    os=$(go env GOOS)
    arch=$(go env GOARCH)
    build "$os" "$arch" ""
    cp "$OUT/fudan-connect-$os-$arch" "$ROOT/Resources/fudan-connect"
    chmod +x "$ROOT/Resources/fudan-connect"
    echo "已更新 Resources/fudan-connect（$VERSION，$os/$arch）"
else
    echo "编译 fudan-connect $VERSION"
    build darwin  arm64 ""
    build darwin  amd64 ""
    build linux   amd64 ""
    build linux   arm64 ""
    build windows amd64 ".exe"
    echo "产物在 build/engine/"
fi
