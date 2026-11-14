import AppKit

let args = CommandLine.arguments
if args.contains("--probe"), let i = args.firstIndex(of: "--probe"), args.count > i + 1 {
    // Probe CLI: đăng nhập (nếu cần) + dịch 1 đoạn, in kết quả, exit.
    let app = NSApplication.shared
    let delegate = ProbeDelegate(text: args[i + 1])
    app.delegate = delegate
    app.setActivationPolicy(.regular) // cần window server cho WKWebView
    app.run()
} else if args.contains("--probe-debug") {
    // Debug: in DOM state 30s để chẩn đoán login/send/bot nodes (không gửi gì).
    let app = NSApplication.shared
    let delegate = DebugProbeDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    _ = NSApplication.shared.run()
}

final class DebugProbeDelegate: NSObject, NSApplicationDelegate {
    private var tick = 0
    private var timer: Timer?

    static let js = "JSON.stringify({"
        + "title: document.title.slice(0, 40),"
        + "bodyLen: document.body ? document.body.innerText.length : -1,"
        + "ta: document.querySelectorAll('textarea').length,"
        + "ce: document.querySelectorAll('[contenteditable]').length,"
        + "inputs: document.querySelectorAll('textarea, [contenteditable], [role=textbox]').length,"
        + "robots: document.querySelectorAll('.message-item-robot, .robot-message, [class*=robot]').length,"
        + "btns: document.querySelectorAll('button').length})"

    func applicationDidFinishLaunching(_ n: Notification) {
        let mgr = DolaWebViewManager.shared
        mgr.webView.load(URLRequest(url: Config.chatURL))
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
            Task { @MainActor in
                var s = "?"
                do { s = try await mgr.webView.evaluateJavaScript(Self.js) as? String ?? "(non-string)" }
                catch { s = "JS-ERR: \(error.localizedDescription)" }
                let u = mgr.webView.url?.absoluteString.prefix(60) ?? "nil"
                let ti = mgr.webView.title?.prefix(40) ?? "nil"
                let lo = mgr.webView.isLoading ? "loading" : "idle"
                print("[debug t+\(self.tick * 3)s] url=\(u) title=\(ti) \(lo) | \(s)")
                self.tick += 1
                if self.tick > 10 { t.invalidate(); exit(0) }
            }
        }
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let text: String
    init(text: String) { self.text = text }

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in
            let mgr = DolaWebViewManager.shared
            do {
                try await mgr.ensureReady()
            } catch {
                print("[probe] cần đăng nhập — mở cửa sổ login…")
                await mgr.presentLoginWindow()
            }
            let stream = mgr.runPrompt(Skill.translate.prompt(for: text))
            var out = ""
            do {
                for try await chunk in stream { out += chunk }
                print("[probe] KẾT QUẢ:", out)
            } catch {
                print("[probe] LỖI:", error.localizedDescription)
                exit(2)
            }
            exit(0)
        }
    }
}
