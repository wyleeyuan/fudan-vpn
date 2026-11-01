#!/bin/bash
# 打包成可直接分发的 DMG：双击挂载，拖进 Applications 即可。
#
#   ./Tools/make_dmg.sh              # 先重新编译 App，再打包
#   SKIP_BUILD=1 ./Tools/make_dmg.sh # 用现成的 FudanVPN.app（CI 里已经编过了）
set -euo pipefail
cd "$(dirname "$0")/.."

APP="FudanVPN.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGE="build/dmg-stage"
DMG="build/FudanVPN-${VERSION}.dmg"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
  echo "[1/4] 跳过编译，用现成的 ${APP}"
  [ -d "$APP" ] || { echo "没有 ${APP}，去掉 SKIP_BUILD 重跑"; exit 1; }
else
  echo "[1/4] 编译 App…"
  ./build.sh >/dev/null
fi

echo "[2/4] 准备安装目录…"
/bin/rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/首次打开必读.txt" <<TXT
复旦 VPN ${VERSION}
==============

安装
  把 FudanVPN.app 拖到 Applications 文件夹。

首次打开
  这个 App 没有经过 Apple 公证（个人项目，没有付费开发者账号），
  所以第一次双击会被拦下，提示「无法验证开发者」。

  正确的打开方式：在 FudanVPN.app 上点右键 → 打开 → 再点「打开」。
  只需要做一次，之后正常双击即可。

  如果系统仍然不让打开，可以在终端执行：
    xattr -dr com.apple.quarantine /Applications/FudanVPN.app

使用
  1. 点「登录」，在弹出的登录页右侧扫微信二维码（也可以账号密码）
  2. 扫完自动回到 App，菜单栏图标从空心变成浅蓝色实心线条即已连接
  3. 需要访问图书馆数据库、CNKI 等按 IP 授权的站点时，
     在菜单里打开「让浏览器走智能分流」，用完关掉

登录页
  手机不在身边也能退：左上角红叉、⌘W、Esc、底部「取消登录」都行。
  关掉只是取消这次登录，不会建立隧道，随时可以再点一次。

账号
  App 不保存学号密码，也不读写钥匙串。扫码同时过掉密码和二次认证。

分流
  默认只把复旦域名和校内网段送进隧道，其余流量直连，
  不会干扰 Clash、Codex 或任何境外服务。

配置文件
  ~/Library/Application Support/FudanVPN/rules.conf
TXT

echo "[3/4] 生成 DMG…"
/bin/rm -f "$DMG"
hdiutil create -volname "复旦 VPN" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

echo "[4/4] 完成"
ls -lh "$DMG"
echo "产物: $PWD/$DMG"
