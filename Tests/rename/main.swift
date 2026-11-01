import Foundation

// 引擎日志的显示改名自测。
//
// 跑法：
//   swiftc -O Sources/TunnelManager.swift Tests/rename/main.swift \
//     -o /tmp/rename_test && /tmp/rename_test

let cases: [(String, String)] = [
    // 上游引擎的真实日志行 → 期望的显示结果
    ("Start ZJU Connect v1.3.1",                       "Start FDU Connect v1.3.1"),
    ("Shutdown ZJU-Connect failed: EOF",               "Shutdown FDU Connect failed: EOF"),
    ("Hijack DNS queries to ZJU Connect",              "Hijack DNS queries to FDU Connect"),
    ("ZJU Connect: host name is not set",              "FDU Connect: host name is not set"),
    ("/usr/bin/zju-connect not found",                 "/usr/bin/fdu-connect not found"),

    // 不含品牌名的行必须原样保留
    ("SOCKS5 server listening on 127.0.0.1:1080",      "SOCKS5 server listening on 127.0.0.1:1080"),
    ("KeepAlive using UDP: OK",                        "KeepAlive using UDP: OK"),
    ("Best node in group abc: 175.186.248.37:441 with quality score 86 ms",
     "Best node in group abc: 175.186.248.37:441 with quality score 86 ms"),
    ("分流代理已启动 127.0.0.1:1082（25 条规则 · 兜底 DIRECT）",
     "分流代理已启动 127.0.0.1:1082（25 条规则 · 兜底 DIRECT）"),

    // 改名后不能再残留任何 zju
    ("Start ZJU Connect v1.3.1",                       "Start FDU Connect v1.3.1")
]

var failed = 0
for (input, expected) in cases {
    let got = TunnelManager.displayText(input)
    let ok = got == expected
    if !ok { failed += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(input)")
    if !ok { print("      期望: \(expected)\n      实际: \(got)") }
    if got.lowercased().contains("zju") {
        failed += 1
        print("      残留 zju: \(got)")
    }
}

print("\n\(cases.count) 条用例，失败 \(failed)")
exit(failed == 0 ? 0 : 1)
