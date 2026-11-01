# engine — VPN 引擎源码

这里是 [Mythologyli/zju-connect](https://github.com/Mythologyli/zju-connect) 的一份
fork，用来给复旦用。原项目是纯 Go 写的 aTrust / EasyConnect 客户端，本来就是
macOS、Linux、Windows 三平台通用（`CGO_ENABLED=0` 交叉编译，产物 14–15 MB）。

放进仓库而不是只放二进制，是为了能自己改两件事：

1. **日志和帮助信息里的品牌** —— 之前只能在 App 侧替换字符串，二进制里还是原样
2. **分流逻辑** —— `dial/dialer.go` 的 `DialIPPort()` 决定一个目标走隧道还是直连，
   复旦真正的分流规则要插在这里

## 改了什么

对照上游 HEAD，只动了用户看得见的部分，功能逻辑没碰：

| 位置 | 改动 |
|---|---|
| `main.go` | 启动/关闭日志：`ZJU Connect` → `FDU Connect` |
| `init.go` | `--help` 的 Usage 名、错误前缀、版本行 |
| `init.go` | 环境变量前缀 `ZJU_CONNECT_*` → `FUDAN_CONNECT_*` |
| `init.go` | 隐藏 `--disable-zju-config`（浙大 easyconnect 专用，保留但不出现在 `--help`） |
| `stack/tun/stack_{windows,linux}.go` | TUN 虚拟网卡名 `FDU Connect` / `FDU-Connect` |
| `*_test.go` | 环境变量前缀同步 |

**没有改 Go module 路径**（还是 `github.com/mythologyli/zju-connect`）。
改了以后每个文件的 import 都要变，跟上游 merge 时会全量冲突。代价是崩溃堆栈里会
出现原来的包名——正常运行不会显示。

## 编

```bash
./Tools/build_engine.sh          # 五个目标全编
./Tools/build_engine.sh --local  # 只编当前平台，并更新 Resources/fudan-connect
```

产物在 `build/engine/`。第一次编要能访问 Go module 代理（`GOPROXY=https://goproxy.cn,direct`）。

## 跟进上游

```bash
git remote add upstream https://github.com/Mythologyli/zju-connect.git
git fetch upstream
git diff upstream/main -- engine   # 先看差异有多大
```

因为改动集中在几个文件的字符串替换上，冲突一般不难处理。合并前先跑
`go test ./...`，上游的测试覆盖还不错（`l3tunnel_lifecycle_test.go` 有 60 KB）。

上游的原始文档留在 `README.upstream.md` / `README.upstream.en.md`，没删。

## 许可

跟上游一样是 **AGPL-3.0**，全文见本目录 `LICENSE`。分发本方编译的二进制时，
按 AGPL 要求需要一并提供这里的源码——本仓库是公开的，满足这一条。
