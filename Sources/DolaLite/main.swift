import AppKit

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private let text: String
    private let skill: Skill
    init(text: String, skill: Skill) { self.text = text; self.skill = skill }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let settings = APISettingsStore()
            let provider = OpenAIProvider(configuration: { try settings.snapshot() })
            let start = Date()
            var firstChunk = true
            do {
                try await provider.ensureReady()
                let snapshot = try settings.snapshot()
                let effort = skill == .translate ? "low" : snapshot.configuration.reasoningEffort
                fputs("[probe] model=\(snapshot.configuration.model) skill=\(skill.rawValue) reasoning=\(effort)\n", stderr)
                for try await chunk in provider.stream(skill: skill, text: text) {
                    if firstChunk {
                        fputs(String(format: "[probe] first_chunk=%.2fs\n", Date().timeIntervalSince(start)), stderr)
                        firstChunk = false
                    }
                    print(chunk, terminator: "")
                    fflush(stdout)
                }
                print("")
                fputs(String(format: "[probe] completed=%.2fs\n", Date().timeIntervalSince(start)), stderr)
                exit(0)
            } catch {
                fputs("[probe] \(error.localizedDescription)\n", stderr)
                exit(2)
            }
        }
    }
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let directory: String
    private var panels: [NSPanel] = []
    init(directory: String) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let pill = PillPanel()
        let result = ResultPanel()
        panels = [pill, result]
        let anchor = NSRect(x: 200, y: 280, width: 200, height: 20)
        pill.show(text: "The quick brown fox jumps over the lazy dog.", near: anchor)
        result.show(skill: .translate, near: anchor)
        result.append("Con cáo nâu nhanh nhẹn nhảy qua con chó lười biếng.\n\nMột trợ lý nhỏ, ngay cạnh đoạn văn bạn chọn.")
        result.finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            do {
                let dir = URL(fileURLWithPath: self.directory, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, panel) in [("pill", pill), ("result", result)] {
                    guard let view = panel.contentView else { continue }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try png.write(to: dir.appendingPathComponent("\(name).png"))
                }
                print("Preview rendered: \(dir.path)")
                exit(0)
            } catch {
                fputs("Preview error: \(error.localizedDescription)\n", stderr)
                exit(2)
            }
        }
    }
}

let args = CommandLine.arguments
MainActor.assumeIsolated {
    if args.contains("--help") {
        print("DolaLite [--probe <text> [--skill translate|summarize|explain]] [--preview <output-directory>]")
    } else {
        let delegate: NSApplicationDelegate
        if let index = args.firstIndex(of: "--probe") {
            guard args.count > index + 1 else { fputs("Thiếu nội dung cho --probe.\n", stderr); exit(2) }
            var skill = Skill.translate
            if let skillIndex = args.firstIndex(of: "--skill") {
                guard args.count > skillIndex + 1, let selected = Skill(rawValue: args[skillIndex + 1]) else {
                    fputs("--skill: translate, summarize hoặc explain.\n", stderr); exit(2)
                }
                skill = selected
            }
            delegate = ProbeDelegate(text: args[index + 1], skill: skill)
        } else if let index = args.firstIndex(of: "--preview"), args.count > index + 1 {
            delegate = PreviewDelegate(directory: args[index + 1])
        } else {
            delegate = AppDelegate()
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
