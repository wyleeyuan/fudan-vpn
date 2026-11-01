import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow?
    private var controller: MainViewController?
    private var statusItem: NSStatusItem?

    // 菜单项只建一次，之后只改标题和状态。
    // 每次状态变化就重建整份菜单的话，菜单开着的时候会被打断。
    private var statusLineItem: NSMenuItem?
    private var connectSwitch: NSSwitch?
    private var proxyCheckbox: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainViewController()
        controller.onPhaseChange = { [weak self] phase in
            self?.refreshStatusItem(phase)
        }
        self.controller = controller

        let win = NSWindow(contentViewController: controller)
        win.title = "复旦 VPN"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 660, height: 590))
        win.minSize = NSSize(width: 560, height: 470)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win

        setupStatusItem()
        refreshStatusItem(controller.currentPhase)

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 常驻

    /// 关窗口只是收起来，隧道和分流器继续跑。
    ///
    /// 这里刻意不真的 close：`orderOut` 保留了窗口对象，`view.window` 一直有效，
    /// 之后从菜单栏点「连接」时登录 sheet 还能正常挂在上面。
    /// 什么都不做、让它关掉的话，下次弹 sheet 会因为窗口已释放而卡住。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller?.showWindow() }
        return true
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        // 只放图标，不带文字：squareLength 正好是一枚 18pt 图标的宽度。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.toolTip = "复旦 VPN"
        }
        statusItem = item
        buildMenu()
    }

    /// 菜单结构（对齐 Clash 的习惯：上面一个大开关，下面是设置项）：
    ///
    ///     ┌──────────────────────────┐
    ///     │ 复旦 VPN            [ ●] │  ← 大开关
    ///     ├──────────────────────────┤
    ///     │ 未连接                    │
    ///     ├──────────────────────────┤
    ///     │ ✓ 让浏览器走智能分流       │
    ///     │   编辑分流规则             │
    ///     ├──────────────────────────┤
    ///     │ 打开窗口                   │
    ///     │ 退出（断开隧道）            │
    ///     └──────────────────────────┘
    private func buildMenu() {
        let menu = NSMenu()
        // 关掉自动校验：默认 NSMenu 会按「target 有没有实现 action」把菜单项重新
        // 置成可用，把 refreshStatusItem 里算好的 isEnabled 覆盖掉。
        // 系统代理那项在隧道没连时要保持灰色。
        menu.autoenablesItems = false

        let switchRow = NSMenuItem()
        switchRow.view = makeSwitchRow()
        menu.addItem(switchRow)

        menu.addItem(.separator())

        let statusLine = NSMenuItem(title: "未连接", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statusLineItem = statusLine

        menu.addItem(.separator())

        let proxy = NSMenuItem(title: "让浏览器走智能分流",
                               action: #selector(toggleProxyFromMenu),
                               keyEquivalent: "")
        proxy.target = self
        menu.addItem(proxy)
        proxyCheckbox = proxy

        let rules = NSMenuItem(title: "编辑分流规则…",
                               action: #selector(openRules),
                               keyEquivalent: "")
        rules.target = self
        menu.addItem(rules)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开窗口", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let quit = NSMenuItem(title: "退出（断开隧道）", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    /// 菜单里塞自定义视图：左边标题，右边一个 Clash 那样的开关。
    private func makeSwitchRow() -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 36))

        let label = NSTextField(labelWithString: "复旦 VPN")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(switchFlipped)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(label)
        host.addSubview(toggle)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),

            toggle.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12)
        ])

        connectSwitch = toggle
        return host
    }

    private func refreshStatusItem(_ phase: TunnelManager.Phase) {
        guard let item = statusItem, let button = item.button else { return }

        let statusText: String
        let iconState: StatusIcon.State
        var connected = false
        var inFlight = false

        switch phase {
        case .connected:
            statusText = "已连接 · 127.0.0.1:\(SplitProxy.port)"
            iconState = .connected
            connected = true
        case .launching:
            statusText = "正在连接…"
            iconState = .connecting
            inFlight = true
        case .idle:
            statusText = "未连接"
            iconState = .idle
        case .failed(let reason):
            statusText = "连接失败 · \(reason)"
            iconState = .failed
        }

        // 自绘校徽章，四种状态都是空心线稿，只换颜色：
        // 跟系统 = 没连，橙 = 正在连，浅蓝 = 通了，红 = 失败。
        button.image = StatusIcon.image(iconState)
        button.image?.isTemplate = StatusIcon.isTemplate(iconState)
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "复旦 VPN — \(statusText)"

        statusLineItem?.title = statusText
        connectSwitch?.state = (connected || inFlight) ? .on : .off

        proxyCheckbox?.state = (controller?.systemProxyEnabled ?? false) ? .on : .off
        proxyCheckbox?.isEnabled = controller?.canToggleSystemProxy ?? false
    }

    // MARK: 菜单动作

    @objc private func switchFlipped() {
        controller?.toggleConnection()
        // 未连接时点开只是弹登录页，phase 还没变；立刻按真实状态把开关拨回去，
        // 免得开关亮着而实际没连上。
        DispatchQueue.main.async { [weak self] in
            guard let self, let phase = self.controller?.currentPhase else { return }
            self.refreshStatusItem(phase)
        }
    }

    @objc private func toggleProxyFromMenu() {
        guard let controller else { return }
        controller.setSystemProxy(!controller.systemProxyEnabled)
        refreshStatusItem(controller.currentPhase)
    }

    @objc private func openRules() {
        controller?.openRules()
    }

    @objc private func openWindow() {
        controller?.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 退出

    /// 退出时回收子进程，否则 fudan-connect 会留在后台占着 1080 端口。
    func applicationWillTerminate(_ notification: Notification) {
        // 先还原系统代理：隧道一断，1080 就不可用，
        // 若把浏览器留在指向 1080 的状态会直接上不了网。
        SystemProxy.restoreIfNeeded()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "FudanVPN.app/Contents/Resources/fudan-connect"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
