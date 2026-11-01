# 复旦 VPN

在校园网外连回校内的轻量客户端。macOS 上是原生 App，Windows 和 Linux 是同一个界面。

它的特点是自带**分**：只有复旦的域名和校内网段走隧道，其余一律直连。所以它不会跟
Clash 抢流量，也不会让 `api.openai.com`、`github.com` 这类请求绕道学校出口。

## 支持平台

| 平台 | 形态 | 下载 |
|---|---|---|
| macOS 13+（Apple Silicon） | 原生 App（菜单栏） | `FudanVPN-x.y.z.dmg` |
| Windows 10 / 11 | 独立窗口程序（x64） | `FudanVPN-x.y.z-windows-amd64.zip` |
| Linux x86_64 | 独立窗口程序，需要 GTK3 / WebKitGTK 4.1 | `FudanVPN-x.y.z-linux-amd64.tar.gz` |
| 服务器 / 树莓派 / 路由器 | 命令行，无图形界面 | `fudan-connect-x.y.z-cli.tar.gz` |

## 安装

**macOS**：下载 DMG，挂载后把 App 拖进「应用程序」。

没有 Apple 公证，**第一次打开要右键 →「打开」**，之后正常双击即可。如果仍然报
「应用已损坏」，在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/FudanVPN.app
```

**Windows**：解压出一个目录，双击 `fudan-vpn.exe`。四个文件必须放在一起，别只把 exe
拖到桌面。首次运行 SmartScreen 可能提示「Windows 已保护你的电脑」，点「更多信息」→
「仍要运行」。

**Linux**：

```bash
tar -xzf FudanVPN-x.y.z-linux-amd64.tar.gz
cd fudan-vpn          # 三个文件放同一目录
./fudan-vpn
```

缺库的话装一下：Debian/Ubuntu 是 `libwebkit2gtk-4.1-0 libgtk-3-0`，
Fedora 是 `webkit2gtk4.1 gtk3`。

**命令行版**：解压后按平台挑一个可执行文件，`./fudan-connect --help` 看参数。

## 使用

三个平台的流程一样，只是登录那一步的交互不同。

1. 点「登录」
2. 用复旦统一身份认证登录（微信扫码，或账号密码 + 二次认证）
3. 登录完地址栏是一条 `https://vpn.fudan.edu.cn/passport/v1/auth/httpsOauth2?code=...`
   的网址
4. 回到程序，点「连接」，状态变成**浅蓝色 / 已连接**就通了

扫一次码同时过掉密码和二级认证，所以程序里没有账号输入框。

**macOS**：登录页在 App 自己的窗口里，扫完码自动回到 App，不用复制粘贴。

**Windows / Linux**：登录页用系统浏览器打开，登录完把**地址栏那一整条网址**复制，
粘进程序里的输入框，点「连接」。多一步粘贴，但不受内嵌浏览器和学校页面的兼容性影响。

**登录窗口随时能关。** 手机不在身边、页面还在转圈、二维码没出来都不影响：左上角红叉、
`⌘W`、`Esc`、底部「取消登录」四条路都能退出。关掉只是取消这次登录，隧道不会建立，
随时可以再点一次。

连上之后本地有三个端口：

| 端口 | 协议 | 行为 |
|---|---|---|
| `1082` | SOCKS5 | **分流口**，按规则决定每条连接走隧道还是直连——日常用这个 |
| `1080` | SOCKS5 | 裸隧道，连进来的全部从复旦出口出去，排错时才用 |
| `1081` | HTTP | 同 1080，只是协议不同 |

## 菜单栏（macOS）

**关窗口不等于断开。** 点红叉只是把窗口收起来，隧道和分流器继续跑。扫完码把窗口关了就行。

图标形状一样，靠颜色区分状态：

| 颜色 | 状态 |
|---|---|
| 跟随系统（浅底黑、深底白） | 未连接 |
| 橙 | 正在连接 |
| **浅蓝** | 已连接 |
| 红 | 连接失败 |

点开菜单，最上面是一个大开关（等价于连接/断开），下面依次是状态行、浏览器代理开关、
编辑分流规则、退出。

## 分流规则

规则文件：

| 平台 | 位置 |
|---|---|
| macOS | `~/Library/Application Support/FudanVPN/rules.conf` |
| Windows | `%APPDATA%\FudanVPN\rules.conf` |
| Linux | `~/.config/FudanVPN/rules.conf` |

程序里点「编辑分流规则」直接打开。格式和 Clash 一样，改完存盘即生效，**不用重启**，
下一次新连接就按新规则走（已建立的连接不受影响）。

```
DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL
IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve
DOMAIN-SUFFIX,cnki.net,TUNNEL
MATCH,DIRECT
```

从上往下逐条匹配，**第一条命中的生效**，都没命中就落到 `MATCH`。所以顺序比条数重要。

| 写法 | 匹配对象 | 例子 |
|---|---|---|
| `DOMAIN,域名,动作` | 完全相等 | `DOMAIN,ehall.fudan.edu.cn,TUNNEL` |
| `DOMAIN-SUFFIX,后缀,动作` | 该域及其所有子域 | `DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL` |
| `DOMAIN-KEYWORD,片段,动作` | 域名里含这个词 | `DOMAIN-KEYWORD,library,TUNNEL` |
| `IP-CIDR,网段,动作[,no-resolve]` | 目标本身是 IP 时 | `IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve` |
| `MATCH,动作` | 兜底，必须放最后 | `MATCH,DIRECT` |

动作只有两个：`TUNNEL`（进隧道）和 `DIRECT`（直连），`PROXY` 视同 `TUNNEL`。
`#` 开头是注释。常见改法：

```
# 实验室还有台机器在 172.20 段
IP-CIDR,172.20.0.0/16,TUNNEL,no-resolve

# 某个镜像站要走校内才通
DOMAIN-SUFFIX,mirrors.fudan.edu.cn,TUNNEL

# 反过来：某个复旦子域反而要走公网
DOMAIN,old.fudan.edu.cn,DIRECT
```

默认只有三类走隧道：复旦域名、内网网段（`10.0.0.0/8`、`172.16.0.0/12`）、
按学校出口 IP 授权的学术库（CNKI、Web of Science、IEEE 等）。
**其余全部直连**，所以 Codex、GitHub、npm 不会被它碰到。

## 接进 Clash（推荐）

分流器不改系统路由，要让流量进来得自己接。三种方式，侵入性从低到高。

**A. 只给浏览器用**

装 SwitchyOmega，把复旦相关域名设成 SOCKS5 `127.0.0.1:1082`，其余保持「系统代理」。
浏览器之外的程序完全不受影响。

**B. 在 Clash 里加一个出站（推荐）**

```yaml
proxies:
  - name: fudan
    type: socks5
    server: 127.0.0.1
    port: 1082

rules:
  - DOMAIN-SUFFIX,fudan.edu.cn,fudan
  - IP-CIDR,10.0.0.0/8,fudan,no-resolve
  - IP-CIDR,172.16.0.0/12,fudan,no-resolve
  # ……其余规则保持你原来的顺序
```

因为 1082 自己也会分流，这里的规则即使写宽了也不会误伤——没命中的连接会在分流器里
直接走本地出口，不会绕复旦。

**C. 勾「让浏览器走智能分流」（macOS）**

把系统 SOCKS 代理指向 1082（HTTP/HTTPS 代理同时关闭）。取消勾选按原样还原，
断开或退出 App 时也会自动还原。适合临时查个文献，不适合长期开着。

## 连校内服务器

`10.x`、`172.16-31.x` 这类内网地址要经过隧道，走 SOCKS5 跳板即可。

**SSH** — `~/.ssh/config`：

```
Host lab
    HostName 10.0.0.5
    User your-username
    ProxyCommand /bin/sh -c "nc -X 5 -x 127.0.0.1:1082 %h %p"
```

（用 1082 而不是 1080：分流口会判内网段走隧道，公网地址仍然直连。Windows 上的
`nc` 可以换成 `connect.exe`，或者直接用 Clash 那条出站规则。）

**VS Code Remote-SSH**：同上，设置里把 `remote.SSH.configFile` 指到这份 config 即可。

**数据库 / Redis 等**：客户端里设 SOCKS5 代理 `127.0.0.1:1082`；不支持代理的，
用 Clash 那条出站规则，或者临时 `ssh -L` 转发端口。

**服务器上跑（命令行版）**：

```bash
./fudan-connect -server vpn.fudan.edu.cn -port 443 \
  -protocol atrust -auth-type auth/httpsOauth2 \
  -login-domain id.fudan.edu.cn -oauth2-code <授权码> \
  -socks-bind 127.0.0.1:1082 -router-rules rules.conf
```

授权码用浏览器登录后从地址栏取，一次性。可以让它常驻跑，然后本地 `ssh -o ProxyCommand`
跳进来。

## 隐私与数据

- **不存学号密码**，不读写钥匙串，程序里没有任何账号输入框
- 登录用的是学校自己的页面，程序只是把网页显示出来，不接触你输入的凭据
- 授权码只在当次连接用一次，用完即弃
- 会话缓存存在本地的 `client_data.json`（与 `rules.conf` 同目录），删掉它下次就要重新扫码
- 分流规则也只是本地文件，不外传
- **没有任何统计上报**。流量只经过三个地方：你的电脑、学校 VPN 服务器、目标网站

## 常见问题

**打开提示「应用已损坏」（macOS）**
没有开发者签名，按上面安装那节的 `xattr` 命令处理，或右键 →「打开」。

**Windows 提示「Windows 已保护你的电脑」**
点「更多信息」→「仍要运行」。程序没有代码签名证书。

**登录页一直转圈 / 二维码不出来**
关掉重开。学校登录页偶尔加载慢，等几秒；仍然不行就用浏览器打开
<https://vpn.fudan.edu.cn> 确认账号本身没问题。

**粘贴了网址，提示「这不是一条完整的网址」**
要的是登录完成后地址栏里**整条** `https://vpn.fudan.edu.cn/passport/v1/auth/httpsOauth2?code=...`。
只复制 `code=` 后面那串也认，但别漏掉前面的部分再手打——`code` 里有大小写和符号。

**连上了但网页打不开**
先确认浏览器或 Clash 的代理指向的是 `1082`。`1080` 是裸隧道，全走复旦，境外站会很慢。

**只有个别站点打不开，别的都正常（比如 `icourse.fudan.edu.cn`）**
这类域名只在校园网内有 DNS 记录，公网查是 NXDOMAIN。走 `1082` 时由隧道那一侧的 DNS
去解析，所以能打开；一旦浏览器没走代理（或者 VPN 已经断开），系统在本机解析就会直接报
「找不到服务器」。确认代理指向 `1082` 即可。`ehall`、`elearning`、`library` 有公网记录，
不受这个限制。

**Ping / ICMP 不通**
设计如此。只代理 TCP，没有 TUN 模式，`ping` 内网机器不会通，用 `nc -vz` 或直接连服务。

**UDP 能用吗**
不能。DNS、游戏、QUIC 之类走不了，浏览器会自动回落到 TCP。

**和 Clash 冲突吗**
不冲突。程序只在 `127.0.0.1` 上开端口，不动系统路由，只有 macOS 上勾选浏览器代理时
才会改系统代理设置，取消即还原。

**每次都要扫码吗**
是。学校授权码一次性，没有「记住这台设备」。登录有效期两小时左右，过期要重新扫。

**Intel Mac 能用吗**
发布的包只含 Apple Silicon。Intel 机器可以自己编：`ARCHS=x86_64 ./build.sh`，
编出来的就是 x86_64 版本。

**怎么彻底卸载**
退出程序，删掉 App 本身和配置目录（`~/Library/Application Support/FudanVPN/`、
`%APPDATA%\FudanVPN\`、`~/.config/FudanVPN/`）。没有后台服务、没有开机项、
没有系统扩展，删完就干净了。

**需要 sudo 吗**
不需要。普通用户权限即可，也没有安装任何守护进程。

## 许可与来源

隧道协议部分来自 [Mythologyli/zju-connect](https://github.com/Mythologyli/zju-connect)，
按 AGPL-3.0 授权。本项目的源码在 `engine/` 下，同样以 **AGPL-3.0** 发布，
完整条款见 [LICENSE](LICENSE)。

校徽仅用于识别用途。
