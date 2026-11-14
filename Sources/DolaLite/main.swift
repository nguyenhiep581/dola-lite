import AppKit

let args = CommandLine.arguments
let app = NSApplication.shared
let delegate: NSApplicationDelegate

if let i = args.firstIndex(of: "--probe"), args.count > i + 1 {
    // Probe CLI (Amendment B): engine Chromium + CDP dịch 1 đoạn, in kết quả, exit.
    delegate = ProbeDelegate(text: args[i + 1])
} else if args.contains("--probe-debug") {
    // Debug: engine launch + openChat rồi dump DOM mỗi 3s qua Runtime.evaluate.
    delegate = DebugProbeDelegate()
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.setActivationPolicy(.accessory)   // engine headless qua CDP — không cần window server
app.run()

/// Dump DOM nhỏ (cùng ngữ cảnh evaluate như pollScript của ChatPageBridge).
final class DebugProbeDelegate: NSObject, NSApplicationDelegate {
    private var tick = 0
    private var timer: Timer?
    private var ready = false

    static let dumpJS = "JSON.stringify({"
        + "bodyLen: document.body ? document.body.innerText.length : -1,"
        + "robots: document.querySelectorAll('.message-item-robot, .robot-message, [class*=robot]').length,"
        + "msgs: document.querySelectorAll('[class*=message]').length,"
        + "bodyText: document.body.innerText.replace(/\\s+/g, ' ').slice(0, 260),"
        + "active: document.activeElement ? document.activeElement.tagName : 'none'"
        + "})"

    func applicationDidFinishLaunching(_ n: Notification) {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
            Task { @MainActor in
                let mgr = DolaEngineManager.shared
                if !self.ready {
                    do {
                        try await mgr.ensureReady()
                        self.ready = true
                        print("[debug] engine ready — chat mở, editor focused")
                    } catch {
                        print("[debug t+\(self.tick * 3)s] ensureReady: \(error.localizedDescription)")
                    }
                }
                if self.ready {
                    // try? + evaluate(String?) đã được Swift flatten → result: String?
                    if let s = try? await mgr.evaluate(Self.dumpJS) {
                        print("[debug t+\(self.tick * 3)s] \(s)")
                    } else {
                        print("[debug t+\(self.tick * 3)s] evaluate lỗi (chưa có string)")
                    }
                }
                self.tick += 1
                if self.tick > 14 {
                    t.invalidate()
                    await mgr.shutdown()
                    exit(0)
                }
            }
        }
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let text: String
    init(text: String) { self.text = text }

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in
            let mgr = DolaEngineManager.shared
            var code: Int32 = 0
            do {
                try await mgr.ensureReady()
                var out = ""
                for try await chunk in mgr.runPrompt(Skill.translate.prompt(for: text)) { out += chunk }
                print("[probe] KẾT QUẢ:", out)
            } catch {
                print("[probe] LỖI:", error.localizedDescription)
                code = 2
            }
            await mgr.shutdown()   // dọn engine trên mọi path rồi exit
            exit(code)
        }
    }
}
