import AppKit

final class MainViewController: NSViewController, NSWindowDelegate {

    private let tunnel = TunnelManager()

    private let statusDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "复旦 VPN")
    private let subtitleLabel = NSTextField(labelWithString: "未连接")
    private let badge = NSTextField(labelWithString: "SOCKS5  127.0.0.1:1080")
    private let actionButton = ActionButton()
    private let proxyToggle = NSButton(checkboxWithTitle: "让浏览器走智能分流（只有校内规则命中的连接进隧道）",
                                       target: nil, action: nil)
    private let rulesButton = NSButton(title: "编辑分流规则", target: nil, action: nil)
    private let statsLabel = NSTextField(labelWithString: "")
    private let logView = NSTextView()

    private var loginWindow: NSWindow?
    private var loginController: LoginWebController?
    /// 授权码已经拿到、马上要建隧道：此时关窗口不算「取消登录」。
    private var loginCommitted = false

    /// 状态变化通知菜单栏，让图标和菜单项跟着变。
    var onPhaseChange: ((TunnelManager.Phase) -> Void)?

    var currentPhase: TunnelManager.Phase { tunnel.phase }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 560))
        buildUI()
        wire()
        render()
    }

    // MARK: 界面搭建

    private func buildUI() {
        let header = makeHeader()
        let div1 = makeDivider()
        let controls = makeControls()
        let div2 = makeDivider()
        let logArea = makeLogArea()

        for v in [header, div1, controls, div2, logArea] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            div1.topAnchor.constraint(equalTo: header.bottomAnchor),
            div1.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            div1.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            div1.heightAnchor.constraint(equalToConstant: 1),

            controls.topAnchor.constraint(equalTo: div1.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            div2.topAnchor.constraint(equalTo: controls.bottomAnchor),
            div2.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            div2.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            div2.heightAnchor.constraint(equalToConstant: 1),

            logArea.topAnchor.constraint(equalTo: div2.bottomAnchor),
            logArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            logArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            logArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            logArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    private func makeHeader() -> NSView {
        let container = NSView()

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        badge.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        badge.textColor = .secondaryLabelColor
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1).cgColor
        badge.layer?.cornerRadius = 5
        badge.alignment = .center
        badge.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [statusDot, textStack, NSView(), badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            badge.heightAnchor.constraint(equalToConstant: 22),
            badge.widthAnchor.constraint(equalToConstant: 170)
        ])
        return container
    }

    private func makeControls() -> NSView {
        let container = NSView()

        actionButton.onClick = { [weak self] in self?.primaryAction() }
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        proxyToggle.target = self
        proxyToggle.action = #selector(toggleBrowserProxy)
        proxyToggle.font = .systemFont(ofSize: 12)
        proxyToggle.translatesAutoresizingMaskIntoConstraints = false

        rulesButton.target = self
        rulesButton.action = #selector(openRulesFile)
        rulesButton.bezelStyle = .inline
        rulesButton.isBordered = false
        rulesButton.contentTintColor = .linkColor
        rulesButton.font = .systemFont(ofSize: 11)
        rulesButton.translatesAutoresizingMaskIntoConstraints = false

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        statsLabel.textColor = .tertiaryLabelColor
        statsLabel.alignment = .right
        statsLabel.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "关掉窗口不会断开连接——App 常驻菜单栏，点图标随时连接或断开。分流器只监听 127.0.0.1:\(SplitProxy.port)，未命中规则的流量一律直连。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(actionButton)
        container.addSubview(proxyToggle)
        container.addSubview(rulesButton)
        container.addSubview(statsLabel)
        container.addSubview(hint)

        NSLayoutConstraint.activate([
            actionButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            actionButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            actionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            actionButton.heightAnchor.constraint(equalToConstant: 34),

            proxyToggle.topAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: 12),
            proxyToggle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            proxyToggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            rulesButton.topAnchor.constraint(equalTo: proxyToggle.bottomAnchor, constant: 10),
            rulesButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),

            statsLabel.centerYAnchor.constraint(equalTo: rulesButton.centerYAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),

            hint.topAnchor.constraint(equalTo: rulesButton.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func makeLogArea() -> NSView {
        let container = NSView()

        let caption = NSTextField(labelWithString: "运行日志")
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.textContainerInset = NSSize(width: 0, height: 4)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = logView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(caption)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    private func makeDivider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }

    // MARK: 事件

    private func wire() {
        tunnel.onPhase = { [weak self] phase in
            guard let self else { return }
            self.handle(phase)
            self.render()
        }
        tunnel.onLog = { [weak self] line in self?.appendLog(line) }

        SplitProxy.shared.onLog = { [weak self] line in self?.appendLog(line) }
        SplitProxy.shared.onStats = { [weak self] tunnelCount, directCount in
            self?.statsLabel.stringValue = "隧道 \(tunnelCount) · 直连 \(directCount)"
        }
    }

    /// 隧道一通就起分流器，断了就收掉——避免留下还在监听 1082 的孤儿。
    private func handle(_ phase: TunnelManager.Phase) {
        switch phase {
        case .connected:
            SplitProxy.shared.resetStats()
            SplitProxy.shared.start()
        default:
            SplitProxy.shared.stop()
        }
        onPhaseChange?(phase)
    }

    private func primaryAction() {
        switch tunnel.phase {
        case .connected, .launching:
            tunnel.disconnect()
        case .idle, .failed:
            presentLogin()
        }
    }

    /// 菜单栏那个「连接 / 断开」调这里。未连接时先把窗口叫出来，
    /// 因为登录 sheet 得挂在一个可见的窗口上。
    func toggleConnection() {
        switch tunnel.phase {
        case .connected, .launching:
            tunnel.disconnect()
        case .idle, .failed:
            showWindow()
            presentLogin()
        }
    }

    func showWindow() {
        guard let win = view.window else { return }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单栏那边也要能开关系统代理，两个入口共用同一份状态。
    var systemProxyEnabled: Bool { SystemProxy.isEnabled }

    var canToggleSystemProxy: Bool { tunnel.phase == .connected }

    func setSystemProxy(_ on: Bool) {
        if on {
            guard tunnel.phase == .connected else {
                syncProxyToggle()
                return
            }
            SystemProxy.enable()
            appendLog("浏览器已切到智能分流：系统 SOCKS -> 127.0.0.1:\(SplitProxy.port)")
        } else {
            SystemProxy.disable()
            appendLog("浏览器已恢复原来的代理设置")
        }
        syncProxyToggle()
    }

    func openRules() {
        openRulesFile()
    }

    // MARK: 登录

    /// 登录页是一个独立的普通窗口，不是 sheet。
    ///
    /// 之前做成 sheet 挂在主窗口上，页面还在转圈、二维码没出来的时候
    /// 既点不到能用的关闭按钮，也没法把登录页单独收起来——手机不在身边
    /// 就卡在那儿了。独立窗口的红叉、⌘W、Esc、底部「取消登录」四条路
    /// 都能随时退出，退出后 phase 仍然是 idle，再点一次登录即可。
    private func presentLogin() {
        if let existing = loginWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = LoginWebController(
            onCode: { [weak self] code in
                guard let self else { return }
                self.loginCommitted = true
                self.dismissLogin()
                self.appendLog("已取得授权码，正在建立隧道…")
                self.tunnel.connect(code: code)
            },
            onFailure: { [weak self] message in
                self?.appendLog("登录页错误: \(message)")
            },
            onStage: { [weak self] stage in
                guard let self, stage == "mfa" else { return }
                self.loginWindow?.title = "请完成二次认证"
                self.appendLog("账号密码已通过，请在窗口里完成二次认证（微信扫码 / 邮箱 / 短信 / OTP）")
                self.appendLog("这是学校强制的两步验证，客户端无法跳过；完成后会自动继续登录。")
            },
            onCancel: { [weak self] in
                self?.cancelLogin()
            }
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "登录复旦 UIS — 微信扫码"
        win.contentViewController = controller
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 540)
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginController = controller
        loginWindow = win
        loginCommitted = false

        appendLog("已打开登录页：右侧二维码可直接扫，扫一次码同时过掉密码和二次认证。")
        appendLog("手机不在身边？点底部「取消登录」或左上角红叉即可退出，随时可以再来。")
    }

    private func dismissLogin() {
        // close() 会走 windowWillClose，引用统一在那里清，避免两处状态不一致。
        loginWindow?.close()
    }

    private func cancelLogin() {
        guard loginWindow != nil else { return }
        loginCommitted = false
        dismissLogin()
    }

    /// 登录窗口被用户关掉（红叉 / ⌘W / Esc / 取消按钮）时收尾。
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === loginWindow else { return }
        loginController?.shutdown()
        loginWindow = nil
        loginController = nil
        if !loginCommitted {
            appendLog("已取消登录，未建立连接——随时可以再点「登录」重新来")
        }
        loginCommitted = false
        render()
        onPhaseChange?(tunnel.phase)
    }

    // MARK: 浏览器代理开关

    @objc private func toggleBrowserProxy() {
        setSystemProxy(proxyToggle.state == .on)
    }

    @objc private func openRulesFile() {
        RoutingRules.writeDefaultIfNeeded()
        let url = RoutingRules.fileURL
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", url.path]
        do {
            try proc.run()
            appendLog("已打开规则文件：\(url.path)")
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 断开或失败时自动收回代理设置，避免把系统留在半截状态。
    private func syncProxyToggle() {
        let connected = tunnel.phase == .connected
        if !connected && SystemProxy.isEnabled {
            SystemProxy.disable()
        }
        proxyToggle.isEnabled = connected
        proxyToggle.state = SystemProxy.isEnabled ? .on : .off
    }

    // MARK: 渲染

    private func setActionTitle(_ text: String) {
        actionButton.setTitle(text)
    }

    private func render() {
        let color: NSColor
        titleLabel.stringValue = "复旦 VPN"

        switch tunnel.phase {
        case .idle:
            color = .secondaryLabelColor
            subtitleLabel.stringValue = "未连接 · 关掉窗口也不会断开，点菜单栏图标可随时连接"
            setActionTitle("登录复旦 UIS")
            actionButton.isEnabled = true

        case .launching:
            color = .systemOrange
            subtitleLabel.stringValue = "正在建立隧道，用授权码换取 aTrust 会话…"
            setActionTitle("取消")
            actionButton.isEnabled = true

        case .connected:
            color = .systemGreen
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            let t = tunnel.connectedAt.map { f.string(from: $0) } ?? ""
            subtitleLabel.stringValue = "已连接 · 隧道建立于 \(t)"
            setActionTitle("断开连接")
            actionButton.isEnabled = true

        case .failed(let reason):
            color = .systemRed
            subtitleLabel.stringValue = "连接失败 · \(reason)"
            setActionTitle("重新登录")
            actionButton.isEnabled = true
        }

        statusDot.layer?.backgroundColor = color.cgColor
        badge.isHidden = tunnel.phase != .connected
        syncProxyToggle()
    }

    private func appendLog(_ line: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        logView.textStorage?.append(NSAttributedString(string: line + "\n", attributes: attrs))
        logView.scrollToEndOfDocument(nil)
    }
}
