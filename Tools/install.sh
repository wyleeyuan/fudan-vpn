#!/bin/bash
# 干净安装到 /Applications。
#
# 为什么不能直接 `ditto FudanVPN.app /Applications/FudanVPN.app`：
# ditto 是**合并**拷贝，不会删掉目标包里的旧文件。改版本时若删掉或改名了某个
# 资源（比如把 zju-connect 改名成 fudan-connect），旧文件会留在包里，而
# _CodeSignature/CodeResources 里没有它 —— codesign 报
# "a sealed resource is missing or invalid"，用户下次打开看到「应用已损坏」。
#
# 所以这里先把旧包整个挪走，再拷一份全新的。
# 用 mv 而不是 rm -rf：万一路径写错，文件还在，能捡回来。

set -euo pipefail
cd "$(dirname "$0")/.."

APP="FudanVPN.app"
DEST="${DEST:-/Applications/$APP}"

if [ ! -d "$APP" ]; then
    echo "找不到 $APP，先跑 ./build.sh"
    exit 1
fi

if ! codesign -v "$APP" 2>/dev/null; then
    echo "构建产物本身签名就不对，先查 build.sh 的签名步骤"
    exit 1
fi

if [ -d "$DEST" ]; then
    STASH="$(mktemp -d)/$APP"
    mv "$DEST" "$STASH"
    echo "旧版本已挪到 $STASH"
fi

mkdir -p "$(dirname "$DEST")"
ditto "$APP" "$DEST"

if codesign -v "$DEST" 2>/dev/null; then
    echo "签名校验通过"
else
    echo "签名校验失败：安装后的包被污染了，检查是否有残留文件"
    exit 1
fi

echo "已安装：$DEST"

if pgrep -f "$DEST/Contents/MacOS/FudanVPN" >/dev/null 2>&1; then
    echo "提示：旧实例仍在运行，退出重开才会用上新版本"
fi
