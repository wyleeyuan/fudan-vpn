import Foundation

/// 管理 fudan-connect 子进程的生命周期。
/// 所有对外回调都切回主线程，UI 层直接更新即可。
final class TunnelManager {

    enum Phase: Equatable {
        case idle
        case launching
        case connected
        case failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet {
            guard oldValue != phase else { return }
            let p = phase
            DispatchQueue.main.async { [weak self] in
                self?.onPhase?(p)
            }
        }
    }

    private(set) var connectedAt: Date?

    var onPhase: ((Phase) -> Void)?
    var onLog: ((String) -> Void)?

    private var process: Process?
    private var pipe: Pipe?
    private var watchdog: DispatchWorkItem?

    // MARK: 路径

    static var binaryURL: URL? {
        Bundle.main.url(forResource: "fudan-connect", withExtension: nil)
    }

    private var clientDataURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FudanVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("client_data.json")
    }

    // MARK: 连接

    func connect(code: String) {
        guard process == nil else { return }
        guard let binary = Self.binaryURL else {
            phase = .failed("App 内缺少 fudan-connect 可执行文件")
            return
        }

        phase = .launching
        connectedAt = nil

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "-protocol",        "atrust",
            "-server",          "vpn.fudan.edu.cn",
            "-port",            "443",
            "-auth-type",       "auth/httpsOauth2",
            "-login-domain",    "id.fudan.edu.cn",
            "-oauth2-code",     code,
            "-bind-interface",  Self.primaryInterface(),
            "-socks-bind",      "127.0.0.1:1080",
            "-http-bind",       "127.0.0.1:1081",
            "-client-data-file", clientDataURL.path
        ]

        // Go 的 net/http 会自动读取这些变量。不清掉的话，
        // 连校内服务器的流量会被系统里配置的代理接管，绕出国再绕回来。
        var env = ProcessInfo.processInfo.environment
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                    "http_proxy", "https_proxy", "all_proxy",
                    "NO_PROXY", "no_proxy"] {
            env.removeValue(forKey: key)
        }
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        self.pipe = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.ingest(text)
        }

        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.watchdog?.cancel()
                self.watchdog = nil
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.pipe = nil
                self.process = nil
                self.connectedAt = nil

                switch self.phase {
                case .connected:
                    self.phase = .failed("隧道已断开（退出码 \(finished.terminationStatus)）")
                case .launching:
                    self.phase = .failed("启动失败（退出码 \(finished.terminationStatus)）")
                default:
                    break
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            startPortWatchdog()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        watchdog?.cancel()
        watchdog = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process?.terminate()
        process = nil
        connectedAt = nil
        phase = .idle
        emit("已手动断开")
    }

    // MARK: 日志

    /// 引擎自报的名字统一换成本项目的名字。
    ///
    /// 隧道引擎是基于 zju-connect 的实现（见 README 的致谢），它启动时会打印
    /// "Start ZJU Connect v1.3.1" 这类自带品牌名的日志。界面上不该出现别人的
    /// 名字，所以在日志出口统一改名——改的是显示文本，不动二进制。
    ///
    /// 不改二进制的原因：Go 的字符串常量是「指针 + 编译期常量长度」，
    /// 换长度会打出乱码，等长替换又要在 arm64 上重新做 ad-hoc 签名，
    /// 而且上游一升级就白改。日志层改名没有这些代价。
    private static let displayRenames: [(from: String, to: String)] = [
        ("Start ZJU Connect", "Start FDU Connect"),
        ("ZJU Connect",       "FDU Connect"),
        ("ZJU-Connect",       "FDU Connect"),
        ("zju-connect",       "fdu-connect")
    ]

    static func displayText(_ line: String) -> String {
        var result = line
        for pair in displayRenames {
            result = result.replacingOccurrences(of: pair.from, with: pair.to)
        }
        return result
    }

    private func ingest(_ text: String) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // 去掉 "2026/11/01 18:30:00 " 前缀
            let raw_body: String
            if line.count > 21, line[line.index(line.startIndex, offsetBy: 4)] == "/" {
                raw_body = String(line.dropFirst(20)).trimmingCharacters(in: .whitespaces)
            } else {
                raw_body = line
            }
            // 先判定状态再用显示文本，避免改名影响关键字匹配
            let body = Self.displayText(raw_body)

            if phase == .launching,
               body.contains("SOCKS") || body.contains("listening") || body.contains("HTTP proxy") {
                connectedAt = Date()
                phase = .connected
            }
        }
    }

    private func emit(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(line)
        }
    }

    /// 兜底：日志里没有可直接匹配的关键字时，直接探 1080 端口。
    private func startPortWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            for _ in 0..<40 {
                guard let self, self.phase == .launching else { return }
                if Self.portIsOpen(port: 1080) {
                    self.connectedAt = Date()
                    self.phase = .connected
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        watchdog = item
        DispatchQueue.global(qos: .utility).async(execute: item)
    }

    private static func portIsOpen(port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    // MARK: 网卡

    /// 默认路由所用的物理网卡。
    /// 把 VPN 底层连接钉在这块网卡上，就完全绕开了 Clash 的 TUN ——
    /// 既不会被送到国外节点绕一圈，也不会触发官方 issue #57 里的死循环。
    static func primaryInterface() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "en0" }
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return "en0" }

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let name = trimmed
                    .replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return "en0"
    }
}
