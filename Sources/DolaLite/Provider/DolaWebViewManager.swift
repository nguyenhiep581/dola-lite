import AppKit
import WebKit

final class DolaWebViewManager: NSObject, WKNavigationDelegate {
    static let shared = DolaWebViewManager()

    let webView: WKWebView
    private var loginWindow: NSWindow?
    private var readyState = false

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent — session sống giữa lần chạy
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/616.1 (KHTML, like Gecko) Version/17.4 Safari/616.1"
        super.init()
        webView.navigationDelegate = self
    }

    /// Load /chat nếu chưa; sẵn sàng khi có editor VÀ có session cookie dola.com còn hiệu lực.
    /// (Trang guest vẫn render editor và body KHÔNG chứa chữ "Log in"/"Đăng nhập" — nút login là
    /// icon — nên detection bằng DOM text sai; session cookie là nguồn chân lý duy nhất.)
    /// Editor có mà không có session cookie → throw notLoggedIn ngay, không đợi hết 12s.
    @MainActor
    func ensureReady() async throws {
        if readyState { return }
        if webView.url == nil { webView.load(URLRequest(url: Config.chatURL)) }
        for _ in 0..<40 {                       // 40 × 0.3s = 12s
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let json = (try? await webView.evaluateJavaScript(ChatPageBridge.probeScript)) as? String,
                  let data = json.data(using: .utf8),
                  let info = try? JSONDecoder().decode(ProbeInfo.self, from: data),
                  info.editorTag != "none" else { continue }
            if Self.hasDolaSession(await Self.allCookies(of: webView)) {
                readyState = true
                return
            }
            throw DolaError.notLoggedIn  // guest state — fail nhanh thay vì timeout 60s
        }
        throw DolaError.notLoggedIn
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

    /// Hiện cửa sổ login (chính webView, tạm visible) tới khi login xong.
    @MainActor
    func presentLoginWindow() async {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Đăng nhập Dola để dùng Dola Lite"
        w.contentView = webView
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loginWindow = w
        while !readyState {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let s = (try? await webView.evaluateJavaScript(ChatPageBridge.probeScript)) as? String,
                  let data = s.data(using: .utf8),
                  let info = try? JSONDecoder().decode(ProbeInfo.self, from: data),
                  info.editorTag != "none" else { continue }
            if Self.hasDolaSession(await Self.allCookies(of: webView)) { readyState = true }
        }
        w.orderOut(nil)   // giữ window sống (webView không dealloc), chỉ ẩn
    }

    /// Gửi prompt + stream text từ node bot mới.
    @MainActor
    func runPrompt(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let result = (try? await webView.evaluateJavaScript(
                    ChatPageBridge.sendScript(prompt: prompt))) as? String ?? "FAIL"
                guard result == "SENT_CLICK" || result == "SENT_ENTER" else {
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
