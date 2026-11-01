import Foundation

// 规则判定的独立自测：swiftc Sources/RoutingRules.swift Tests/rules_test.swift -o /tmp/rules_test

let rules = RoutingRules.parse(RoutingRules.defaultText)
var failed = 0

func check(_ host: String, _ port: UInt16, _ expect: RouteDecision) {
    let got = rules.decide(host: host, port: port)
    let ok = got == expect
    if !ok { failed += 1 }
    print("\(ok ? "✓" : "✗") \(host):\(port) → \(got.rawValue)\(ok ? "" : "  (期望 \(expect.rawValue))")")
}

print("=== 必须直连（Clash 的地盘，绝不能碰）===")
check("api.openai.com", 443, .direct)
check("chatgpt.com", 443, .direct)
check("github.com", 443, .direct)
check("registry.npmjs.org", 443, .direct)
check("www.google.com", 443, .direct)
check("1.1.1.1", 443, .direct)
check("192.168.1.1", 80, .direct)      // 家里路由，最容易被误伤的一个
check("127.0.0.1", 7890, .direct)
check("172.32.0.1", 80, .direct)       // 172.32 不在 172.16/12 内，边界

print("\n=== 必须进隧道 ===")
check("ehall.fudan.edu.cn", 443, .tunnel)
check("fudan.edu.cn", 443, .tunnel)
check("www.fudan.edu.cn", 443, .tunnel)
check("10.0.0.5", 22, .tunnel)         // 内网机器
check("10.0.0.1", 443, .tunnel)
check("172.16.0.1", 80, .tunnel)       // 172.16/12 下界
check("172.31.255.254", 80, .tunnel)   // 172.16/12 上界
check("www.cnki.net", 443, .tunnel)
check("ieee.org", 443, .tunnel)
check("webofscience.com", 443, .tunnel)

print("\n=== 后缀匹配不能误伤 ===")
check("notfudan.edu.cn", 443, .direct)      // 只是结尾像
check("fudan.edu.cn.evil.com", 443, .direct) // 拼在前面的假域名
check("myfudan.edu.cn", 443, .direct)        // 独立域名，不是 fudan.edu.cn 的子域
check("my.fudan.edu.cn", 443, .tunnel)       // 真子域

print("\n=== 自定义规则 ===")
let custom = RoutingRules.parse("""
DOMAIN-SUFFIX,example.com,TUNNEL
DOMAIN,only.this.cn,TUNNEL
DOMAIN-KEYWORD,internal,TUNNEL
IP-CIDR,10.1.0.0/16,TUNNEL,no-resolve
MATCH,DIRECT
""")
let a = custom.decide(host: "a.example.com", port: 443) == .tunnel
let b = custom.decide(host: "only.this.cn", port: 443) == .tunnel
let c = custom.decide(host: "xx.internal.yy", port: 443) == .tunnel
let d = custom.decide(host: "10.1.2.3", port: 80) == .tunnel
let e = custom.decide(host: "10.2.2.3", port: 80) == .direct
let f = custom.decide(host: "only.this.cn.evil.com", port: 443) == .direct
for (name, ok) in [("后缀", a), ("精确", b), ("关键词", c), ("/16 命中", d), ("/16 未命中", e), ("精确不匹配子域", f)] {
    if !ok { failed += 1 }
    print("\(ok ? "✓" : "✗") \(name)")
}

print("\n\(failed == 0 ? "全部通过" : "\(failed) 项失败")")
exit(failed == 0 ? 0 : 1)
