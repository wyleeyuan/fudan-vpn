import Foundation

/// 分流判定结果。
enum RouteDecision: String {
    case tunnel = "TUNNEL"
    case direct = "DIRECT"

    var text: String {
        switch self {
        case .tunnel: return "隧道"
        case .direct: return "直连"
        }
    }
}

/// Clash 风格的规则表。
///
/// 兼容 Clash 的写法，一条规则一行，形如：
///
///     DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL
///     DOMAIN,ehall.fudan.edu.cn,TUNNEL
///     DOMAIN-KEYWORD,chsi,TUNNEL
///     IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve
///     MATCH,DIRECT
///
/// 动作只支持两个：`TUNNEL`（送进复旦隧道）和 `DIRECT`（本机直连）。
/// 为兼容 Clash 习惯，`PROXY` 视同 `TUNNEL`，`REJECT` 不支持（会按 DIRECT 处理）。
///
/// 判定只做「字符串后缀匹配 + IP 网段匹配」，不做 DNS 解析。
/// 原因是 Clash 开 TUN 时会返回 fake-ip（198.18.0.0/15），拿解析结果判断域名的
/// 校内校外必然误判；而 10.x 这类内网地址本来就不会走 DNS，当 IP 字面量处理即可。
struct RoutingRules {

    enum Kind {
        case domain          // 精确匹配
        case domainSuffix    // 后缀匹配
        case domainKeyword   // 包含
        case ipCIDR          // 网段
        case match           // 兜底，永远命中
    }

    struct Rule {
        let kind: Kind
        let value: String
        let decision: RouteDecision
        let source: String
    }

    private(set) var rules: [Rule] = []
    private(set) var fallback: RouteDecision = .direct

    // MARK: 判定

    func decide(host: String, port: UInt16) -> RouteDecision {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let ip = IPv4Address(name)

        for rule in rules {
            switch rule.kind {
            case .match:
                return rule.decision

            case .domain:
                if name == rule.value { return rule.decision }

            case .domainSuffix:
                if name == rule.value || name.hasSuffix("." + rule.value) {
                    return rule.decision
                }

            case .domainKeyword:
                if name.contains(rule.value) { return rule.decision }

            case .ipCIDR:
                // 只有目标本身就是 IP 时才比较。域名交给上面几条域名规则，
                // 绝不为了套 CIDR 去解析它（fake-ip 会让结论完全错）。
                if let ip, rule.value.contains(ip) { return rule.decision }
            }
        }
        return fallback
    }

    // MARK: 解析

    static func parse(_ text: String) -> RoutingRules {
        var result = RoutingRules()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // 去掉行尾注释，但保留 DOMAIN 里可能出现的 #（正常域名没有，直接切）
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // 容忍从 Clash 配置里连带粘进来的 "  - " 列表前缀
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            if line.hasSuffix(",") { line = String(line.dropLast()) }

            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }

            let type = fields[0].uppercased()
            let value = fields.count >= 2 ? fields[1].lowercased() : ""
            let actionRaw = fields.count >= 3 ? fields[2].uppercased() : ""

            // MATCH 后面没有域名参数：MATCH,DIRECT
            if type == "MATCH" || type == "FINAL" {
                let action = parseAction(fields.count >= 2 ? fields[1] : "DIRECT")
                result.fallback = action
                result.rules.append(Rule(kind: .match, value: "", decision: action, source: line))
                continue
            }

            guard let kind = kind(for: type) else { continue }
            let action = parseAction(actionRaw)
            guard !value.isEmpty else { continue }
            result.rules.append(Rule(kind: kind, value: value, decision: action, source: line))
        }

        if result.rules.isEmpty {
            return .default
        }
        return result
    }

    private static func kind(for type: String) -> Kind? {
        switch type {
        case "DOMAIN":                return .domain
        case "DOMAIN-SUFFIX":         return .domainSuffix
        case "DOMAIN-KEYWORD":        return .domainKeyword
        case "IP-CIDR", "IP-CIDR6":   return .ipCIDR
        default:                      return nil
        }
    }

    private static func parseAction(_ text: String) -> RouteDecision {
        switch text {
        case "TUNNEL", "PROXY", "FUDAN", "VPN": return .tunnel
        default: return .direct
        }
    }

    // MARK: 默认规则

    static let `default` = RoutingRules.parse(defaultText)

    static let defaultText: String = """
    # 复旦 VPN 分流规则（Clash 写法）
    #
    # 动作：
    #   TUNNEL  送进复旦隧道（192.168.0.0/16 之类永远不会命中，放心）
    #   DIRECT  本机直连，交给系统网络（Clash 该怎么走还怎么走）
    #
    # 改完存盘即生效，不需要重启 App（下次新建连接时读取）。
    # 这份文件同时可以直接粘进 FlClash 的 rules: 段，写法完全一样。

    # ── 复旦校内 ──────────────────────────────────────────
    DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL
    DOMAIN-SUFFIX,fudan.sh.cn,TUNNEL
    DOMAIN-SUFFIX,fudanpress.com,TUNNEL

    # ── 内网网段（GPU 服务器、实验室机器）───────────────
    IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve
    IP-CIDR,172.16.0.0/12,TUNNEL,no-resolve

    # ── 需要学校出口 IP 才能用的学术库 ───────────────────
    DOMAIN-SUFFIX,cnki.net,TUNNEL
    DOMAIN-SUFFIX,cnki.com.cn,TUNNEL
    DOMAIN-SUFFIX,webofscience.com,TUNNEL
    DOMAIN-SUFFIX,webofknowledge.com,TUNNEL
    DOMAIN-SUFFIX,clarivate.com,TUNNEL
    DOMAIN-SUFFIX,ieee.org,TUNNEL
    DOMAIN-SUFFIX,acm.org,TUNNEL
    DOMAIN-SUFFIX,springer.com,TUNNEL
    DOMAIN-SUFFIX,nature.com,TUNNEL
    DOMAIN-SUFFIX,science.org,TUNNEL
    DOMAIN-SUFFIX,sciencedirect.com,TUNNEL
    DOMAIN-SUFFIX,elsevier.com,TUNNEL
    DOMAIN-SUFFIX,wiley.com,TUNNEL
    DOMAIN-SUFFIX,tandfonline.com,TUNNEL
    DOMAIN-SUFFIX,jstor.org,TUNNEL
    DOMAIN-SUFFIX,ebsco.com,TUNNEL
    DOMAIN-SUFFIX,proquest.com,TUNNEL
    DOMAIN-SUFFIX,scopus.com,TUNNEL
    DOMAIN-SUFFIX,wanfangdata.com.cn,TUNNEL
    DOMAIN-SUFFIX,cqvip.com,TUNNEL

    # ── 其余一律直连 ──────────────────────────────────────
    # OpenAI / Anthropic / GitHub / npm 等都不在上面，永远不会被送进隧道。
    MATCH,DIRECT
    """

    // MARK: 读写

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FudanVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL {
        directory.appendingPathComponent("rules.conf")
    }

    static func load() -> RoutingRules {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            writeDefaultIfNeeded()
            return .default
        }
        return parse(text)
    }

    /// 首次运行把默认规则落盘，用户才能改。
    static func writeDefaultIfNeeded() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? defaultText.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Clash 片段：给要把复旦接进 FlClash 的人直接复制。
    static func clashSnippet(port: UInt16 = 1082) -> String {
        """
        # ── 粘进 FlClash 的 proxies: 段 ──
        #   - name: fudan
        #     type: socks5
        #     server: 127.0.0.1
        #     port: \(port)
        #
        # ── 粘进 rules: 段（放在 MATCH 之前）──
        """
    }

    var summary: String {
        let tunnel = rules.filter { $0.decision == .tunnel }.count
        return "\(tunnel) 条规则 · 兜底 \(fallback.rawValue)"
    }
}

// MARK: - IPv4 与 CIDR

struct IPv4Address {
    let raw: UInt32

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        raw = value
    }
}

extension String {
    /// `"10.0.0.0/8".contains(ip)`
    func contains(_ ip: IPv4Address) -> Bool {
        let halves = split(separator: "/", maxSplits: 1)
        guard let base = IPv4Address(String(halves[0])) else { return false }
        let bits = halves.count > 1 ? (Int(halves[1]) ?? 32) : 32
        guard bits >= 0, bits <= 32 else { return false }
        if bits == 0 { return true }
        let mask: UInt32 = bits == 32 ? 0xFFFF_FFFF : ~(0xFFFF_FFFF >> UInt32(bits))
        return (ip.raw & mask) == (base.raw & mask)
    }
}
