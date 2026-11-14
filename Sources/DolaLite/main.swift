import AppKit

let args = CommandLine.arguments
if args.contains("--probe"), let i = args.firstIndex(of: "--probe"), args.count > i + 1 {
    // Probe CLI: đăng nhập (nếu cần) + dịch 1 đoạn, in kết quả, exit.
    let app = NSApplication.shared
    let delegate = ProbeDelegate(text: args[i + 1])
    app.delegate = delegate
    app.setActivationPolicy(.regular) // cần window server cho WKWebView
    app.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    _ = NSApplication.shared.run()
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
