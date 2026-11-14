import AppKit
import WebKit

final class DolaWebViewManager: NSObject, WKNavigationDelegate {
    static let shared = DolaWebViewManager()

    let webView: WKWebView
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
