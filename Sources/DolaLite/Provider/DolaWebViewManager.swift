import AppKit
import WebKit

/// NSWindow borderless mặc định canBecomeKey == false → makeKey() vô hiệu hóa.
/// WKWebView cần window key để WebKit xử lý text input như trusted keyboard input.
private final class HostKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class DolaWebViewManager: NSObject, WKNavigationDelegate {
    static let shared = DolaWebViewManager()

    let webView: WKWebView
    private var hostWindow: NSWindow?
    private var readyState = false

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent — session sống giữa lần chạy
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/616.1 (KHTML, like Gecko) Version/17.4 Safari/616.1"
        super.init()
        webView.navigationDelegate = self
    }

    /// Load /chat nếu chưa; sẵn sàng khi có editor VÀ session cookie dola.com còn hiệu lực
    /// (trang guest vẫn render editor nên editorTag không đủ kết luận login).
    /// Chưa có session → tự import từ profile Dola (Amendment A) → reload → poll lại tối đa 30s.
    @MainActor
    func ensureReady() async throws {
        if readyState { return }
        if webView.url == nil { webView.load(URLRequest(url: Config.chatURL)) }

        // Phase 1 — 12s: chờ trang lên + editor. Có editor mà chưa session → import.
        var needImport = false
        for _ in 0..<40 {                       // 40 × 0.3s = 12s
            try await Task.sleep(nanoseconds: 300_000_000)
            guard await probeEditor() != nil else { continue }
            if Self.hasDolaSession(await Self.allCookies(of: webView)) {
                readyState = true
                return
            }
            needImport = true
            break
        }
        guard needImport else { throw DolaError.notLoggedIn }  // trang/editor không lên trong 12s

        // Phase 2 — import session từ profile Dola rồi poll lại tối đa 30s.
        do {
            try await SessionImporter.importSession(into: webView.configuration.websiteDataStore)
        } catch {
            throw DolaError.notLoggedIn  // profile chưa login hoặc browser phụ fail
        }
        webView.load(URLRequest(url: Config.chatURL))
        for _ in 0..<100 {                      // 100 × 0.3s = 30s
            try await Task.sleep(nanoseconds: 300_000_000)
            guard await probeEditor() != nil else { continue }
            if Self.hasDolaSession(await Self.allCookies(of: webView)) {
                readyState = true
                return
            }
        }
        throw DolaError.notLoggedIn
    }

    /// Probe DOM; trả ProbeInfo khi editor xuất hiện (textarea/contenteditable), nil nếu chưa.
    @MainActor
    private func probeEditor() async -> ProbeInfo? {
        guard let json = (try? await webView.evaluateJavaScript(ChatPageBridge.probeScript)) as? String,
              let data = json.data(using: .utf8),
              let info = try? JSONDecoder().decode(ProbeInfo.self, from: data),
              info.editorTag != "none" else { return nil }
        return info
    }

    /// true khi có session cookie dola.com còn hiệu lực.
    static func hasDolaSession(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { c in
            (c.domain.hasSuffix("dola.com")) && ["sessionid", "sid_guard", "sessionid_ss"].contains(c.name)
        }
    }

    /// Lấy toàn bộ cookie trong data store của webView (async wrapper của httpCookieStore.getAllCookies).
    @MainActor
    static func allCookies(of webView: WKWebView) async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    struct ProbeInfo: Decodable { let editorTag: String; let botSelector: String?; let botCount: Int }

    /// WKWebView phải nằm trong window thật để nhận first responder + NSEvent.
    /// Off-screen (−2000,−2000): vô hình với user nhưng window còn sống nhận input.
    /// KHÔNG set alphaValue 0 — một số phiên bản WebKit bỏ event với window alpha 0.
    @MainActor
    private func ensureHostWindow() {
        guard hostWindow == nil else { return }
        let w = HostKeyWindow(contentRect: NSRect(x: -2000, y: -2000, width: 480, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.hasShadow = false
        w.contentView = webView
        w.orderFrontRegardless()
        w.makeKey()
        hostWindow = w
    }

    /// Gõ prompt bằng input THẬT của macOS (NSResponder) — synthetic DOM events
    /// (Enter/click/pointer-seq/execCommand) bị editor framework của dola chặn hoàn toàn.
    /// insertText → text như gõ bàn phím; Return = NSEvent keyCode 36 route đúng
    /// keyDown→keyDown, keyUp→keyUp theo responder chain.
    @MainActor
    func typePrompt(_ prompt: String) async throws {
        ensureHostWindow()
        // focus editor trong page (chỉ focus — KHÔNG set text)
        _ = try? await webView.evaluateJavaScript(
            "(() => { const ed = document.querySelector('[contenteditable=true]') || document.querySelector('textarea'); if (ed) { ed.focus(); return 'focused'; } return 'no-editor'; })()")
        try? await Task.sleep(nanoseconds: 200_000_000)
        hostWindow?.makeFirstResponder(webView)
        try? await Task.sleep(nanoseconds: 100_000_000)
        webView.insertText(prompt)          // NSResponder — text input trusted như bàn phím
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Enter thật
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: Date().timeIntervalSinceReferenceDate,
                windowNumber: hostWindow?.windowNumber ?? 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                switch type {
                case .keyDown: webView.keyDown(with: ev)
                case .keyUp:   webView.keyUp(with: ev)
                default: break
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Gửi prompt + stream text từ node bot mới.
    /// Flow: focus editor + baseline → gõ thật (typePrompt) → poll node bot mới.
    @MainActor
    func runPrompt(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let result = (try? await webView.evaluateJavaScript(
                    ChatPageBridge.focusAndBaselineScript)) as? String ?? "FAIL"
                guard result == "FOCUSED" else {
                    continuation.finish(throwing: DolaError.sendFailed); return
                }
                do {
                    try await typePrompt(prompt)
                } catch {
                    continuation.finish(throwing: DolaError.sendFailed); return
                }
                let deadline = Date().addingTimeInterval(Config.streamTimeoutSec)
                var lastEmitted = ""
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(Config.pollIntervalMs * 1_000_000_000))
                    guard let json = (try? await webView.evaluateJavaScript(ChatPageBridge.pollScript)) as? String,
                          let r = try? ChatPageBridge.parsePollResult(json) else { continue }
                    if r.found, r.text.count > lastEmitted.count {
                        continuation.yield(String(r.text.dropFirst(lastEmitted.count)))
                        lastEmitted = r.text
                    }
                    if r.stable { continuation.finish(); return }
                }
                continuation.finish(throwing: DolaError.timeout)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
