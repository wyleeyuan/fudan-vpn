import Foundation

/// App 与引擎之间约定的本地端口。
enum LocalPorts {
    /// 分流口：按 rules.conf 决定每条连接走隧道还是直连。日常用这个。
    static let split: UInt16 = 1082
    /// 裸隧道口：全部从学校出口出去，排错时用。
    static let tunnel: UInt16 = 1080
    /// 裸隧道的 HTTP 版本。
    static let http: UInt16 = 1081
}

/// 分流规则文件的位置。
///
/// 真正解析规则的是引擎（`engine/router`），App 这边只负责两件事：
/// 文件不存在时放一份默认规则、以及用编辑器把它打开。
/// 规则写错了不会静默跳过——引擎会在日志里报出行号。
enum SplitRules {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("FudanVPN/rules.conf")
    }

    /// 默认规则只有一份源：`engine/router/default_rules.conf`，
    /// 打包时由 build.sh 复制进 Contents/Resources。这里只做拷贝。
    static func writeDefaultIfNeeded() {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) { return }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        if let template = Bundle.main.url(forResource: "rules", withExtension: "conf"),
           let text = try? String(contentsOf: template, encoding: .utf8) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            // 包里没带模板（例如直接从源码目录跑），至少留一条兜底，
            // 免得用户打开一个空文件不知道写什么。
            let minimal = """
            # 复旦 VPN 分流规则
            # 默认规则模板没找到，先给一份最简版本。
            DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL
            IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve
            IP-CIDR,172.16.0.0/12,TUNNEL,no-resolve
            MATCH,DIRECT

            """
            try? minimal.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
