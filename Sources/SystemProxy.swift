import Foundation

/// 负责「浏览器是否走校内网络」这件事。
///
/// 开启时把系统 SOCKS 代理指向隧道端口 1080，同时关掉原来的 HTTP/HTTPS 代理；
/// 关闭时按开启前保存的快照原样还原。
///
/// 之所以不做成 PAC：macOS 27 上 `file://` 的 PAC 不会被浏览器执行，
/// 而 `http://` 的 PAC 需要一个常驻服务，代价远高于收益。
/// ehall 这类站点是「开着用、用完关」的短时需求，一键切换反而更直观。
final class SystemProxy {

    /// 网络服务名。拿不到时退回 Wi-Fi。
    private static var serviceName: String {
        cachedService ?? "Wi-Fi"
    }

    private static var cachedService: String?

    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FudanVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var snapshotURL: URL {
        supportDir.appendingPathComponent("proxy-snapshot.json")
    }

    private struct Snapshot: Codable {
        var httpEnabled: Bool
        var httpServer: String
        var httpPort: Int
        var httpsEnabled: Bool
        var httpsServer: String
        var httpsPort: Int
        var socksEnabled: Bool
        var socksServer: String
        var socksPort: Int
    }

    /// 当前是否处于「浏览器走校内网络」状态。
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    // MARK: 开关

    /// 把系统 SOCKS 指向分流代理。默认走 1082 而不是 1080 ——
    /// 1080 是「全都送进复旦」的裸隧道，1082 才会按规则判断，
    /// 只有命中规则的域名/网段进隧道，其余直连。
    @discardableResult
    static func enable(port: UInt16 = SplitProxy.port) -> Bool {
        guard !isEnabled else { return true }

        resolveServiceName()
        let snap = readSnapshot()
        save(snap)

        run(["-setsocksfirewallproxy", serviceName, "127.0.0.1", "\(port)"])
        run(["-setwebproxystate", serviceName, "off"])
        run(["-setsecurewebproxystate", serviceName, "off"])
        return true
    }

    static func disable() {
        guard let snap = load() else { return }
        restore(snap)
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    /// 进程退出或隧道断开时兜底，避免把用户的代理设置留在半截状态。
    static func restoreIfNeeded() {
        guard isEnabled else { return }
        disable()
    }

    // MARK: 还原

    private static func restore(_ snap: Snapshot) {
        if snap.httpEnabled {
            run(["-setwebproxy", serviceName, snap.httpServer, "\(snap.httpPort)"])
        } else {
            run(["-setwebproxystate", serviceName, "off"])
        }

        if snap.httpsEnabled {
            run(["-setsecurewebproxy", serviceName, snap.httpsServer, "\(snap.httpsPort)"])
        } else {
            run(["-setsecurewebproxystate", serviceName, "off"])
        }

        if snap.socksEnabled {
            run(["-setsocksfirewallproxy", serviceName, snap.socksServer, "\(snap.socksPort)"])
        } else {
            run(["-setsocksfirewallproxystate", serviceName, "off"])
        }
    }

    // MARK: 快照读写

    private static func readSnapshot() -> Snapshot {
        let http = parse(get(["-getwebproxy", serviceName]))
        let https = parse(get(["-getsecurewebproxy", serviceName]))
        let socks = parse(get(["-getsocksfirewallproxy", serviceName]))

        return Snapshot(
            httpEnabled: http.enabled, httpServer: http.server, httpPort: http.port,
            httpsEnabled: https.enabled, httpsServer: https.server, httpsPort: https.port,
            socksEnabled: socks.enabled, socksServer: socks.server, socksPort: socks.port
        )
    }

    private static func save(_ snap: Snapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: snapshotURL)
    }

    private static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func parse(_ text: String) -> (enabled: Bool, server: String, port: Int) {
        var enabled = false
        var server = ""
        var port = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Enabled": enabled = (value == "Yes")
            case "Server": server = value
            case "Port": port = Int(value) ?? 0
            default: break
            }
        }
        return (enabled, server, port)
    }

    // MARK: 网络服务名

    /// 找出默认路由网卡对应的网络服务名（多半是 Wi-Fi，但也可能是有线）。
    private static func resolveServiceName() {
        if cachedService != nil { return }

        let iface = TunnelManager.primaryInterface()
        let order = get(["-listnetworkserviceorder"])

        // 输出形如：
        // (1) Wi-Fi
        // (Hardware Port: Wi-Fi, Device: en0)
        var lastService: String?
        for raw in order.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(") && line.contains(") ") && !line.contains("Hardware Port") {
                if let close = line.firstIndex(of: ")") {
                    lastService = String(line[line.index(after: close)...])
                        .trimmingCharacters(in: .whitespaces)
                }
            } else if line.contains("Device: \(iface)") {
                if let name = lastService, !name.isEmpty {
                    cachedService = name
                    return
                }
            }
        }
        cachedService = "Wi-Fi"
    }

    // MARK: 执行

    private static let binary = "/usr/sbin/networksetup"

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    private static func get(_ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
