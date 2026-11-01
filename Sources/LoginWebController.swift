import AppKit
import WebKit

/// 复旦统一身份认证的授权入口。
///
/// redirect_uri 必须与 aTrust 服务端下发的完全一致，服务端会校验 sfDomain，
/// 改动任何一个字符都会导致 code 换不回会话。
enum FudanAuth {

    static let loginURLString: String = {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "id.fudan.edu.cn"
        comps.path = "/idp/authCenter/authenticate"
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: "vpn"),
            URLQueryItem(name: "redirect_uri",
                         value: "https://vpn.fudan.edu.cn/passport/v1/auth/httpsOauth2?sfDomain=id.fudan.edu.cn"),
            URLQueryItem(name: "response_type", value: "code")
        ]
        return comps.url?.absoluteString
            ?? "https://id.fudan.edu.cn/idp/authCenter/authenticate"
    }()

    static let callbackHost = "vpn.fudan.edu.cn"
    static let callbackPath = "/passport/v1/auth/httpsOauth2"

    static func extractCode(from url: URL) -> String? {
        guard url.host == callbackHost, url.path.contains(callbackPath) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "code" }?
            .value
    }
}

/// 内嵌登录页。登录页右边自带微信二维码，扫一次码同时过掉密码和二次认证，
/// 所以这里不做任何自动填充——只做三件事：
///
/// 1. 在导航层拦下回调 URL，取走授权码（不经过剪贴板）
/// 2. 检测到二级认证页时通知上层，把窗口标题改成「请完成二次认证」
/// 3. 底部固定一条「取消登录」，随时能退——不用等二维码出来，
///    哪怕页面还在转圈、手机不在身边也能直接关掉
final class LoginWebController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    private let onCode: (String) -> Void
    private let onFailure: (String) -> Void
    private let onStage: (String) -> Void
    private let onCancel: () -> Void

    private var webView: WKWebView!
    private var hintLabel: NSTextField!
    private var cancelButton: NSButton!
    private var keyMonitor: Any?
    private var delivered = false
    private static let handlerName = "fudanStage"

    init(onCode: @escaping (String) -> Void,
         onFailure: @escaping (String) -> Void,
         onStage: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.onCode = onCode
        self.onFailure = onFailure
        self.onStage = onStage
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.handlerName)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 700))

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let controller = WKUserContentController()
        controller.add(self, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.stageScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.translatesAutoresizingMaskIntoConstraints = false

        // 底部工具条：左边一句提示，右边「取消登录」。
        // 这是 sheet 里点不到红叉时的逃生口，也是关窗口之外的第二条路。
        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        hintLabel = NSTextField(labelWithString: "手机不在身边？直接点「取消登录」，随时可以再来。")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let reload = NSButton(title: "重新加载", target: self, action: #selector(reloadTapped))
        reload.bezelStyle = .inline
        reload.isBordered = false
        reload.contentTintColor = .linkColor
        reload.font = .systemFont(ofSize: 12)
        reload.translatesAutoresizingMaskIntoConstraints = false

        cancelButton = NSButton(title: "取消登录", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.font = .systemFont(ofSize: 12)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(divider)
        footer.addSubview(hintLabel)
        footer.addSubview(reload)
        footer.addSubview(cancelButton)

        root.addSubview(web)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 50),

            divider.topAnchor.constraint(equalTo: footer.topAnchor),
            divider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            hintLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 18),
            hintLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: reload.leadingAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            reload.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -14),
            reload.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        view = root
        webView = web

        if let url = URL(string: FudanAuth.loginURLString) {
            web.load(URLRequest(url: url))
        } else {
            onFailure("登录地址构造失败")
        }
    }

    // MARK: 退出

    override func viewDidAppear() {
        super.viewDidAppear()
        // WKWebView 会把 Esc 吃掉，所以用本地事件监听兜一层：
        // 只有登录窗口是 key window 时才响应，不影响主窗口。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  self.view.window?.isKeyWindow == true else { return event }
            self.onCancel()
            return nil
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        shutdown()
    }

    /// 关窗口时主动拆掉两样东西：
    ///
    /// - 本地 Esc 监听（不然每开一次登录页就多一个）
    /// - `WKUserContentController` 对 self 的强引用（它会让 deinit 永远不跑，
    ///   每取消一次登录就漏一个 WebView）
    ///
    /// 重复调用是安全的。
    func shutdown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        webView?.stopLoading()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.handlerName)
    }

    @objc private func cancelTapped() {
        onCancel()
    }

    @objc private func reloadTapped() {
        delivered = false
        guard let url = URL(string: FudanAuth.loginURLString) else { return }
        webView.load(URLRequest(url: url))
        hintLabel.stringValue = "手机不在身边？直接点「取消登录」，随时可以再来。"
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let code = FudanAuth.extractCode(from: url) {
            decisionHandler(.cancel)
            guard !delivered else { return }
            delivered = true
            onCode(code)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if delivered { return }
        hintLabel.stringValue = "二维码在页面右侧；手机不在身边就点「取消登录」，随时可以再来。"
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        // 自己取消的那一次也会走这里，忽略
        if (error as NSError).code == NSURLErrorCancelled { return }
        hintLabel.stringValue = "页面加载失败：\(error.localizedDescription)（可以点「重新加载」）"
        onFailure(error.localizedDescription)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let stage = body["stage"] as? String
        else { return }
        onStage(stage)
    }

    // MARK: - 注入脚本

    /// 复旦的登录是两段式：密码通过后还要过二级认证（微信扫码/邮箱/短信/OTP），
    /// 这是学校强制的，客户端绕不过去。脚本只负责报告「现在轮到你了」。
    ///
    /// 页面是 Vue SPA，`document.body` 在内层路由切换时不重建，所以轮询而不是
    /// 监听一次 DOMContentLoaded；命中后立刻停表，不留后台定时器。
    static let stageScript = #"""
    (function () {
      if (window.__fudanStageInjected) { return; }
      window.__fudanStageInjected = true;

      var sent = false;
      var timer = setInterval(function () {
        if (sent) { return; }
        var text = document.body ? (document.body.innerText || '') : '';
        if (/二级认证|二次认证|为确保账户安全/.test(text)) {
          sent = true;
          clearInterval(timer);
          try {
            window.webkit.messageHandlers.__HANDLER__.postMessage({ stage: 'mfa' });
          } catch (e) {}
        }
      }, 700);
    })();
    """#
    .replacingOccurrences(of: "__HANDLER__", with: handlerName)
}
