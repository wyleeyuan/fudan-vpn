import Foundation

// 分流代理的链路测试：不需要真隧道，只验证 SOCKS5 握手与「直连」分支。
//
//   swiftc -O Sources/RoutingRules.swift Sources/SplitProxy.swift Tests/proxy/main.swift -o /tmp/proxy_test
//   /tmp/proxy_test &
//   curl --socks5-hostname 127.0.0.1:1082 http://127.0.0.1:8081/

SplitProxy.shared.onLog = { line in
    print("[log] \(line)")
    fflush(stdout)
}
SplitProxy.shared.onStats = { tunnel, direct in
    print("[stats] 隧道 \(tunnel) · 直连 \(direct)")
    fflush(stdout)
}

print("启动分流器…")
SplitProxy.shared.start()

// 跑 10 分钟，够手动打完几轮
RunLoop.main.run(until: Date().addingTimeInterval(600))
print("退出")
