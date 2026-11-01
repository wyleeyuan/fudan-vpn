import Foundation
import Network

/// 本地 SOCKS5 分流代理。
///
/// 它只做一件事：把「该走复旦」的连接转给 fudan-connect 的 1080，其余自己直连。
/// 监听地址固定 `127.0.0.1:1082`，**从不主动修改系统代理**——要不要用它，
/// 由用户在 Clash 里加一条 outbound，或给某个程序单独设代理决定。
///
/// 这样分流和 Clash 是叠加关系而不是竞争关系：
/// 没有指向 1082 的流量，一条都不会经过这里，Codex / npm / GitHub 完全不受影响。
final class SplitProxy {

    static let shared = SplitProxy()
    static let port: UInt16 = 1082
    static let upstreamPort: UInt16 = 1080

    private let queue = DispatchQueue(label: "local.fudan.vpn.split")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: SplitSession] = [:]

    private var rules: RoutingRules = .default
    private var rulesStamp: Date?

    var onLog: ((String) -> Void)?
    var onStats: ((Int, Int) -> Void)?

    private(set) var tunnelCount = 0
    private(set) var directCount = 0
    private(set) var running = false

    private init() {}

    // MARK: 生命周期

    /// 隧道连上之后调用。启动失败只记日志，不影响主隧道。
    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }

            RoutingRules.writeDefaultIfNeeded()
            self.reloadRules(force: true)

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.port)!
            )

            do {
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] conn in
                    self?.accept(conn)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.log("分流代理已启动 127.0.0.1:\(Self.port)（\(self.rules.summary)）")
                        self.log("规则文件：\(RoutingRules.fileURL.path)")
                    case .failed(let error):
                        self.running = false
                        self.log("分流代理启动失败：\(error.localizedDescription)")
                    case .cancelled:
                        self.running = false
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                self.log("分流代理无法监听 \(Self.port)：\(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.running = false
            let all = self.sessions.values
            self.sessions.removeAll()
            for session in all { session.close() }
        }
    }

    /// 每次重新连上隧道时把计数清零。
    func resetStats() {
        queue.async { [weak self] in
            self?.tunnelCount = 0
            self?.directCount = 0
            self?.reportStats()
        }
    }

    // MARK: 规则

    /// 规则文件改动后自动重读，不用重启 App。
    private func reloadRules(force: Bool = false) {
        let url = RoutingRules.fileURL
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if !force, stamp == rulesStamp { return }
        rulesStamp = stamp
        rules = RoutingRules.load()
        if !force { log("分流规则已重新加载：\(rules.summary)") }
    }

    // MARK: 连接

    private func accept(_ conn: NWConnection) {
        let session = SplitSession(
            client: conn,
            queue: queue,
            rules: { [weak self] in
                guard let self else { return .default }
                self.reloadRules()
                return self.rules
            },
            onDecide: { [weak self] host, port, decision in
                guard let self else { return }
                switch decision {
                case .tunnel: self.tunnelCount += 1
                case .direct: self.directCount += 1
                }
                let short = host.count > 44 ? String(host.prefix(41)) + "…" : host
                self.log("\(short):\(port) → \(decision.text)")
                self.reportStats()
            },
            onFinish: { [weak self] session in
                self?.sessions.removeValue(forKey: ObjectIdentifier(session))
            }
        )
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    private func reportStats() {
        let tunnel = tunnelCount
        let direct = directCount
        DispatchQueue.main.async { [weak self] in
            self?.onStats?(tunnel, direct)
        }
    }

    private func log(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(line)
        }
    }
}

// MARK: - 单条连接

private final class SplitSession: Hashable {

    private enum Stage {
        case greeting, request, connecting, relaying, closed
    }

    private enum UpstreamStage {
        case method, reply, done
    }

    private let client: NWConnection
    private let queue: DispatchQueue
    private let rules: () -> RoutingRules
    private let onDecide: (String, UInt16, RouteDecision) -> Void
    private let onFinish: (SplitSession) -> Void

    private var stage: Stage = .greeting
    private var buffer = Data()
    private var upstream: NWConnection?
    private var upstreamBuffer = Data()
    private var upstreamStage: UpstreamStage = .method

    private var clientReceiving = false
    private var upstreamReceiving = false

    /// 客户端原始请求里的 ATYP+ADDR+PORT，转发给上游时原样带上，
    /// 这样域名可以交给远端解析，不在本地产生 DNS 泄漏。
    private var rawTarget = Data()
    private var targetHost = ""
    private var targetPort: UInt16 = 0

    init(client: NWConnection,
         queue: DispatchQueue,
         rules: @escaping () -> RoutingRules,
         onDecide: @escaping (String, UInt16, RouteDecision) -> Void,
         onFinish: @escaping (SplitSession) -> Void) {
        self.client = client
        self.queue = queue
        self.rules = rules
        self.onDecide = onDecide
        self.onFinish = onFinish
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.readClient()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    func close() {
        guard stage != .closed else { return }
        stage = .closed
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        upstream = nil
        onFinish(self)
    }

    // MARK: 客户端 → 我们

    /// 同一时刻只允许一个 receive 在飞，否则 Network.framework 会直接崩。
    private func readClient() {
        guard !clientReceiving, stage != .closed else { return }
        clientReceiving = true
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self, self.stage != .closed else { return }
            self.clientReceiving = false
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.pumpClient()
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.readClient()
            }
        }
    }

    private func pumpClient() {
        switch stage {
        case .greeting:
            // VER(1) NMETHODS(1) METHODS(n)
            guard buffer.count >= 2 else { readClient(); return }
            let methods = Int(buffer[buffer.startIndex + 1])
            guard buffer.count >= 2 + methods else { readClient(); return }
            buffer.removeFirst(2 + methods)
            stage = .request
            client.send(content: Data([0x05, 0x00]), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.close(); return }
                self.pumpClient()
            })

        case .request:
            guard buffer.count >= 4 else { readClient(); return }

            guard let parsed = parseRequest() else {
                // 4 字节以上还解析不出来，说明是真的畸形请求，直接断
                if buffer.count > 512 { close() } else { readClient() }
                return
            }
            buffer.removeFirst(parsed.length)
            rawTarget = parsed.raw
            targetHost = parsed.host
            targetPort = parsed.port

            guard parsed.command == 0x01 else {
                failToClient(code: 0x07)   // 只支持 CONNECT
                return
            }

            let decision = rules().decide(host: targetHost, port: targetPort)
            onDecide(targetHost, targetPort, decision)
            stage = .connecting

            switch decision {
            case .tunnel: connectTunnel()
            case .direct: connectDirect()
            }

        default:
            break
        }
    }

    private struct ParsedRequest {
        let command: UInt8
        let host: String
        let port: UInt16
        let raw: Data
        let length: Int
    }

    private func parseRequest() -> ParsedRequest? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 4 else { return nil }
        let command = bytes[1]
        let atyp = bytes[3]

        var host = ""
        var addrLength = 0

        switch atyp {
        case 0x01:
            guard bytes.count >= 10 else { return nil }
            host = "\(bytes[4]).\(bytes[5]).\(bytes[6]).\(bytes[7])"
            addrLength = 4
        case 0x03:
            guard bytes.count >= 5 else { return nil }
            let len = Int(bytes[4])
            guard bytes.count >= 5 + len + 2 else { return nil }
            host = String(bytes: bytes[5..<(5 + len)], encoding: .utf8) ?? ""
            addrLength = 1 + len
        case 0x04:
            guard bytes.count >= 22 else { return nil }
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { dst in
                dst.copyBytes(from: bytes[4..<20])
            }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &text, socklen_t(INET6_ADDRSTRLEN))
            host = String(cString: text)
            addrLength = 16
        default:
            return nil
        }

        let portOffset = 4 + addrLength
        guard bytes.count >= portOffset + 2 else { return nil }
        let port = UInt16(bytes[portOffset]) << 8 | UInt16(bytes[portOffset + 1])
        let total = portOffset + 2

        // 注意：buffer 被 removeFirst 过，startIndex 不一定从 0 开始，
        // subdata 要按真实索引取，否则直接崩在越界。
        let base = buffer.startIndex
        return ParsedRequest(
            command: command,
            host: host,
            port: port,
            raw: buffer.subdata(in: (base + 3)..<(base + total)),
            length: total
        )
    }

    // MARK: 上游：隧道（1080）

    private func connectTunnel() {
        let conn = NWConnection(
            to: .hostPort(host: .ipv4(.loopback),
                          port: NWEndpoint.Port(rawValue: SplitProxy.upstreamPort)!),
            using: .tcp
        )
        upstream = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.upstreamStage = .method
                conn.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { error in
                    if error != nil { self.failToClient(code: 0x01) }
                })
                self.readUpstream()
            case .failed:
                self.failToClient(code: 0x05)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func readUpstream() {
        guard let conn = upstream, !upstreamReceiving, stage != .closed else { return }
        upstreamReceiving = true
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self, self.stage != .closed else { return }
            self.upstreamReceiving = false
            if let data, !data.isEmpty {
                self.upstreamBuffer.append(data)
                self.pumpUpstream()
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.readUpstream()
            }
        }
    }

    private func pumpUpstream() {
        guard let conn = upstream else { return }

        switch upstreamStage {
        case .method:
            guard upstreamBuffer.count >= 2 else { readUpstream(); return }
            let bytes = [UInt8](upstreamBuffer)
            guard bytes[0] == 0x05, bytes[1] == 0x00 else {
                failToClient(code: 0x01)
                return
            }
            upstreamBuffer.removeFirst(2)

            var payload = Data([0x05, 0x01, 0x00])
            payload.append(rawTarget)
            upstreamStage = .reply
            conn.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.failToClient(code: 0x01); return }
                self.pumpUpstream()
            })

        case .reply:
            let bytes = [UInt8](upstreamBuffer)
            guard bytes.count >= 4 else { readUpstream(); return }
            guard bytes[1] == 0x00 else {
                failToClient(code: 0x05)
                return
            }
            let atyp = bytes[3]
            let replyLength: Int
            switch atyp {
            case 0x01: replyLength = 10
            case 0x04: replyLength = 22
            case 0x03:
                guard bytes.count >= 5 else { readUpstream(); return }
                replyLength = 4 + 1 + Int(bytes[4]) + 2
            default:
                failToClient(code: 0x01)
                return
            }
            guard upstreamBuffer.count >= replyLength else { readUpstream(); return }
            upstreamBuffer.removeFirst(replyLength)

            upstreamStage = .done
            replyToClient(code: 0x00)

        case .done:
            break
        }
    }

    // MARK: 上游：直连

    private func connectDirect() {
        let port = NWEndpoint.Port(rawValue: targetPort) ?? 0
        let conn = NWConnection(to: .hostPort(host: NWEndpoint.Host(targetHost), port: port), using: .tcp)
        upstream = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.replyToClient(code: 0x00)
            case .waiting(let error):
                NSLog("[split] direct waiting \(self.targetHost):\(self.targetPort) \(error)")
            case .failed(let error):
                NSLog("[split] direct failed \(self.targetHost):\(self.targetPort) \(error)")
                self.failToClient(code: 0x05)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    // MARK: 回复客户端

    /// 成功回复固定填 `0.0.0.0:0`——客户端不会回连这个地址，够用。
    private func replyToClient(code: UInt8) {
        guard stage == .connecting else { return }
        stage = .relaying
        let reply = Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        client.send(content: reply, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close(); return }
            if code != 0x00 {
                self.close()
            } else {
                self.startRelay()
            }
        })
    }

    private func failToClient(code: UInt8) {
        guard stage != .closed else { return }
        if stage == .relaying { close(); return }
        stage = .connecting
        replyToClient(code: code)
    }

    // MARK: 双向透传

    /// 不能在这里再判 `stage == .connecting`：`replyToClient` 已经把 stage
    /// 推进到 `.relaying` 了，那样会直接 return，连接建起来却永远不转发。
    private var relayStarted = false

    private func startRelay() {
        guard !relayStarted, let conn = upstream else { return }
        relayStarted = true
        stage = .relaying

        if !buffer.isEmpty {
            let pending = buffer
            buffer.removeAll(keepingCapacity: false)
            conn.send(content: pending, completion: .contentProcessed { _ in })
        }
        // 上游握手阶段可能留了数据，一并倒给客户端
        if !upstreamBuffer.isEmpty {
            let pending = upstreamBuffer
            upstreamBuffer.removeAll(keepingCapacity: false)
            client.send(content: pending, completion: .contentProcessed { _ in })
        }

        relay(from: client, to: conn)
        relay(from: conn, to: client)
    }

    private var relayActive = false

    private func relay(from source: NWConnection, to dest: NWConnection) {
        relayActive = true
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.stage != .closed else { return }

            if let data, !data.isEmpty {
                dest.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { self.close(); return }
                    self.relay(from: source, to: dest)
                })
            } else if isComplete {
                dest.send(content: nil,
                          contentContext: .defaultMessage,
                          isComplete: true,
                          completion: .contentProcessed { _ in })
            } else if error != nil {
                self.close()
            } else {
                self.relay(from: source, to: dest)
            }
        }
    }

    // MARK: Hashable

    static func == (lhs: SplitSession, rhs: SplitSession) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
