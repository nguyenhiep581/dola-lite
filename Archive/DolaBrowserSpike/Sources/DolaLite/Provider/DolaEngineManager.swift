import Darwin
import Foundation

/// Engine Chromium thường trú điều khiển qua CDP — Amendment B (thay WKWebView).
///
/// Sau 8 vòng thử input vào WKWebView đều bị dola chặn (synthetic DOM events,
/// execCommand, NSResponder insertText, per-char NSEvent, NSEvent mouse click),
/// user duyệt chuyển sang cơ chế đã proven trong spike Phase 0
/// (docs/notes/phase0-findings.md §4.5): "Dola Browser" chạy riêng với bản copy
/// profile Cici + điều khiển qua CDP — Input.insertText + Input.dispatchKeyEvent
/// (Enter) trả kết quả dịch thật.
///
/// Vòng đời (plan Amendment B):
///   launch:     rsync profile → tmp (exclude cache/Singleton*) → browser headless
///               --saman-from-chat=<pid> --remote-debugging-port=<9300..9399>
///               --no-first-run about:blank → poll /json/version (20s)
///   openChat:   PUT /json/new?<encoded> → page ws URL → ws giữ sống
///   ensureReady: Runtime.evaluate(focusAndBaselineScript) == "FOCUSED" (30s)
///   runPrompt:  focusAndBaseline → Input.insertText → Enter keyDown/keyUp
///               → poll pollScript mỗi 300ms → yield → stable / timeout 60s
///   shutdown:   Browser.close → đợi exit 5s → terminate → rm tmp (mọi path)
///
/// Ràng buộc: read-only profile gốc (chỉ rsync đọc); kill chỉ process mình spawn;
/// tmp dọn sạch trên mọi path; không log cookie/secret values (engine không
/// đọc/ghi cookie nào — session do browser copy tự giữ).
@MainActor
final class DolaEngineManager {
    static let shared = DolaEngineManager()

    // MARK: State (toàn bộ truy cập trên MainActor; receive loop chạy background)

    private var tmpDir: URL?
    private var browser: Process?
    private var port: Int?
    private var router: CDPRouter?
    private var ready = false
    private var launching: Task<Void, Error>?

    private init() {}

    // MARK: - Lifecycle

    /// Đảm bảo engine sống + trang chat mở + editor nhận focus. Idempotent;
    /// caller đến đồng thời thì cùng đợi một launch task duy nhất (fail → mọi
    /// caller nhận cùng lỗi). Session chat đến từ bản copy profile — browser tự
    /// decrypt cookie bằng keychain như spike, app không đụng cookie.
    func ensureReady() async throws {
        if ready { return }
        if let inFlight = launching {
            try await inFlight.value
            return
        }
        let task = Task { @MainActor in
            do {
                try await launchEngine()
                try await openChat()
                try await waitUntilFocused(timeout: 30)
                ready = true
            } catch {
                await shutdown()   // dọn tmp + stop process trên mọi path lỗi
                throw error
            }
        }
        launching = task
        defer { launching = nil }
        try await task.value
    }

    /// Gửi prompt bằng input TRUSTED của Chromium (proven spike §4.5) rồi stream
    /// text từ node bot mới. Script JS dùng lại nguyên ChatPageBridge.
    func runPrompt(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish(throwing: DolaError.sendFailed)
                    return
                }
                do {
                    // 1) Focus editor + baseline số bot node (focusAndBaselineScript giữ nguyên).
                    guard try await self.evaluate(ChatPageBridge.focusAndBaselineScript) == "FOCUSED",
                          let router = self.router else {
                        continuation.finish(throwing: DolaError.sendFailed)
                        return
                    }
                    // 2) Gõ text như bàn phím thật; 3) Enter submit (keyDown rồi keyUp).
                    _ = try await Self.withTimeout(10) {
                        try await router.call("Input.insertText", Self.insertTextParams(prompt))
                    }
                    for type in ["keyDown", "keyUp"] {
                        _ = try await Self.withTimeout(10) {
                            try await router.call("Input.dispatchKeyEvent", Self.enterKeyParams(type: type))
                        }
                    }
                    // 4) Poll node bot mới mỗi 300ms → yield delta; stable → finish; 60s → timeout.
                    let deadline = Date().addingTimeInterval(Config.streamTimeoutSec)
                    var lastEmitted = ""
                    while Date() < deadline {
                        try await Task.sleep(nanoseconds: UInt64(Config.pollIntervalMs * 1_000_000_000))
                        guard let json = try? await self.evaluate(ChatPageBridge.pollScript),
                              let r = try? ChatPageBridge.parsePollResult(json) else { continue }
                        if r.found, r.text.count > lastEmitted.count {
                            continuation.yield(String(r.text.dropFirst(lastEmitted.count)))
                            lastEmitted = r.text
                        }
                        if r.stable {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish(throwing: DolaError.timeout)
                } catch let error as DolaError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: DolaError.sendFailed)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runtime.evaluate một expression trong trang chat, trả về string value
    /// (nil khi value không phải string). Event frame từ ws không bao giờ lẫn
    /// vào kết quả vì router match response theo id.
    func evaluate(_ expression: String) async throws -> String? {
        guard let router else { throw DolaError.pageNotReady }
        let response = try await Self.withTimeout(10) {
            try await router.call("Runtime.evaluate", Self.evaluateParams(expression))
        }
        if Self.cdpErrorMessage(response) != nil {
            // Ví dụ "Cannot find default execution context" khi trang đang navigate.
            throw DolaError.pageNotReady
        }
        return Self.evaluateResultValue(response)
    }

    /// Dọn sạch: Browser.close (best-effort qua ws) → đợi exit 5s → SIGTERM →
    /// đợi 2s → rm tmp. Idempotent; gọi trên mọi path (thành công lẫn lỗi).
    func shutdown() async {
        ready = false
        launching = nil
        if let router {
            _ = try? await Self.withTimeout(5) {
                try await router.call("Browser.close", nil)
            }
            router.close()   // fail mọi pending + kết thúc receive loop
        }
        router = nil
        if let browser {
            await Self.stopProcess(browser)
        }
        browser = nil
        port = nil
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
    }

    // MARK: - Launch steps (private)

    /// rsync profile Cici → tmp/profile → browser headless → poll /json/version.
    private func launchEngine() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DolaLite-engine-\(UUID().uuidString)", isDirectory: true)
        let profile = tmp.appendingPathComponent("profile", isDirectory: true)
        tmpDir = tmp   // gán trước mọi bước có thể fail để shutdown luôn dọn được

        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try await Self.runProcess(Self.rsyncPath, args: Self.rsyncArgs(from: Self.profileSource, to: profile))

        guard let port = Self.findFreePort() else { throw DolaError.notLoggedIn }
        self.port = port
        browser = try Self.launchBrowser(profile: profile, port: port)

        guard await Self.pollDevToolsURL(port: port, timeout: 20) != nil else {
            throw DolaError.notLoggedIn   // browser phụ không lên DevTools
        }
    }

    /// PUT /json/new?<encoded chat URL> → page webSocketDebuggerUrl → ws giữ sống.
    private func openChat() async throws {
        guard let port else { throw DolaError.notLoggedIn }
        var req = URLRequest(url: Self.newTabURL(port: port, chat: Config.chatURL))
        req.httpMethod = "PUT"
        req.timeoutInterval = 10
        struct NewTab: Decodable { let webSocketDebuggerUrl: String }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let tab = try? JSONDecoder().decode(NewTab.self, from: data),
              let pageWS = URL(string: tab.webSocketDebuggerUrl) else {
            throw DolaError.notLoggedIn
        }
        let router = CDPRouter(ws: URLSession.shared.webSocketTask(with: pageWS))
        router.start()
        self.router = router
    }

    /// Poll focusAndBaselineScript tới khi trang chat load xong editor ("FOCUSED").
    private func waitUntilFocused(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await evaluate(ChatPageBridge.focusAndBaselineScript),
               value == "FOCUSED" { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw DolaError.pageNotReady
    }
}

// MARK: - Helpers absorbed từ SessionImporter + pure CDP builders (unit test được)

extension DolaEngineManager {

    /// Profile nguồn đã login trên máy user (read-only — chỉ rsync đọc).
    nonisolated static var profileSource: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cici")
    }

    /// Engine Chromium (fork Dola đi kèm Cici) — binary proven ở spike Phase 0.
    nonisolated static let browserBinary =
        "/Applications/Cici.app/Contents/Helpers/Dola Browser.app/Contents/MacOS/Dola Browser"

    nonisolated static let rsyncPath = "/usr/bin/rsync"

    // MARK: Pure CDP builders (format lock với spec Amendment B)

    /// Runtime.evaluate params; response string đọc ở `result.result.value`.
    nonisolated static func evaluateParams(_ expression: String) -> [String: Any] {
        ["expression": expression, "returnByValue": true]
    }

    /// Input.insertText params — text như gõ bàn phím TRUSTED (proven spike).
    nonisolated static func insertTextParams(_ text: String) -> [String: Any] {
        ["text": text]
    }

    /// Input.dispatchKeyEvent params cho Enter submit — keyDown và keyUp gọi riêng.
    nonisolated static func enterKeyParams(type: String) -> [String: Any] {
        ["type": type, "key": "Enter", "code": "Enter",
         "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13]
    }

    /// Request envelope {"id":..,"method":..,"params":{..}} — params đi qua
    /// JSONSerialization nên mọi escape (newline/quote) đúng chuẩn JSON.
    nonisolated static func envelope(id: Int, method: String, params: [String: Any]?) -> Data {
        var obj: [String: Any] = ["id": id, "method": method]
        if let params { obj["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// Đọc string value từ response Runtime.evaluate: result.result.value.
    nonisolated static func evaluateResultValue(_ response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              let remoteObject = result["result"] as? [String: Any] else { return nil }
        return remoteObject["value"] as? String
    }

    /// Lỗi CDP ({"error":{"code":..,"message":..}}) nếu response báo lỗi.
    nonisolated static func cdpErrorMessage(_ response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["message"] as? String
    }

    /// Endpoint mở tab mới: PUT /json/new?<fully-encoded chat URL>.
    /// Fix round 1 (Task 2B): fork này chỉ chấp nhận dạng query CŨ của DevTools —
    /// query KHÔNG có tên param (`/json/new?<url>`); dạng `?url=<url>` bị bỏ qua
    /// → tab mở thành about:blank → ensureReady poll editor mãi mãi (pageNotReady).
    /// Verify A/B của controller trên cùng engine đang sống: `?url=...` → about:blank,
    /// `?...` → đúng trang chat trong /json/list.
    nonisolated static func newTabURL(port: Int, chat: URL) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "."))
        let encoded = chat.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed)!
        return URL(string: "http://127.0.0.1:\(port)/json/new?\(encoded)")!
    }

    // MARK: Process / network helpers (absorbed từ SessionImporter, proven fix round 3-4)

    nonisolated static func rsyncArgs(from src: URL, to dst: URL) -> [String] {
        let excludes = [
            "Default/GPUCache", "Default/Dawn*", "Default/ShaderCache", "Default/GraphiteDawnCache",
            "Default/Cache", "Default/Code Cache", "Crashpad", "BrowserMetrics*",
            "component_crx_cache", "GrShaderCache",
            // Fix round 4: Singleton* symlinks trỏ sang socket của browser CHÍNH đang chạy —
            // browser phụ đọc SingletonLock → tưởng instance khác tồn tại → delegate & exit ngay.
            // RunningChromeVersion cũng chỉ meaningful cho instance đang chạy.
            "Singleton*", "RunningChromeVersion",
        ]
        var args = ["-a"]
        for e in excludes { args += ["--exclude", e] }
        args.append(src.path + "/")
        args.append(dst.path + "/")
        return args
    }

    nonisolated static func runProcess(_ path: String, args: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(
                        domain: "DolaEngineManager", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(path) exited \(proc.terminationStatus)"]))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Headless luôn (Amendment B — proven sống cùng --saman-from-chat).
    /// about:blank PHẢI là arg cuối; handshake --saman-from-chat=<pid> giữ nguyên
    /// (giả parent Cici — không có nó browser exit ngay qua cơ chế repair của fork).
    nonisolated static func launchBrowser(profile: URL, port: Int) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: browserBinary)
        p.arguments = [
            "--user-data-dir=\(profile.path)",
            "--saman-from-chat=\(getpid())",
            "--remote-debugging-port=\(port)",
            "--no-first-run",
            "--headless=new",
            "about:blank",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Đợi process thoát tối đa 5s (Browser.close đã gửi); không thì SIGTERM rồi
    /// đợi thêm 2s — chỉ process mình spawn.
    nonisolated static func stopProcess(_ p: Process) async {
        let softDeadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < softDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning { p.terminate() }
        let hardDeadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < hardDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Tìm port còn tự do trong 9300...9399 bằng bind thử trên loopback.
    nonisolated static func findFreePort() -> Int? {
        for port in 9300...9399 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ok == 0 { return port }
        }
        return nil
    }

    /// Poll GET /json/version tới khi DevTools lên; trả về webSocketDebuggerUrl.
    nonisolated static func pollDevToolsURL(port: Int, timeout: TimeInterval) async -> URL? {
        struct Version: Decodable { let webSocketDebuggerUrl: String }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/json/version")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (data, _) = try? await URLSession.shared.data(from: endpoint),
               let v = try? JSONDecoder().decode(Version.self, from: data),
               let ws = URL(string: v.webSocketDebuggerUrl) {
                return ws
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// Race op với timeout — trả URLError.timedOut nếu op chậm hơn `seconds`.
    /// (Op task bị cancel khi thua race — CDPRouter.call cancellation-aware.)
    nonisolated static func withTimeout<T>(_ seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let first = try await g.next()!
            g.cancelAll()
            return first
        }
    }
}

// MARK: - CDP router (ws giữ sống, match response theo id)

/// Một WebSocketTask CDP sống lâu với receive-loop chạy trên background task.
/// Mọi message đọc lên: frame có `id` khớp pending continuation → resume;
/// frame KHÔNG có `id` (event, ví dụ frame đầu sau khi connect) → drop.
final class CDPRouter: @unchecked Sendable {
    private let ws: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false

    init(ws: URLSessionWebSocketTask) {
        self.ws = ws
    }

    /// Resume ws + bắt đầu receive loop (gọi một lần sau khi tạo).
    func start() {
        ws.resume()
        Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    /// Gửi request và chờ response cùng id. Hỗ trợ cancellation (withTimeout
    /// race-cancel) — continuation không bao giờ treo vĩnh viễn.
    func call(_ method: String, _ params: [String: Any]?) async throws -> [String: Any] {
        let id: Int = lock.withLock {
            nextID += 1
            return nextID
        }
        let payload = String(decoding: DolaEngineManager.envelope(id: id, method: method, params: params), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                let stored: Bool = lock.withLock {
                    guard !closed else { return false }
                    pending[id] = cont
                    return true
                }
                guard stored else {
                    cont.resume(throwing: DolaError.pageNotReady)
                    return
                }
                ws.send(.string(payload)) { [weak self] error in
                    guard let self, let error else { return }
                    let c = self.lock.withLock { self.pending.removeValue(forKey: id) }
                    c?.resume(throwing: error)
                }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            let c = self.lock.withLock { self.pending.removeValue(forKey: id) }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Đóng ws (sau Browser.close) — fail mọi pending, receive loop tự kết thúc.
    func close() {
        let all = drainPending(markClosed: true)
        for c in all { c.resume(throwing: DolaError.pageNotReady) }
        ws.cancel(with: .goingAway, reason: nil)
    }

    // MARK: Private

    private func receiveLoop() async {
        while true {
            let obj: [String: Any]
            do {
                let msg = try await ws.receive()
                guard case .string(let text) = msg,
                      let data = text.data(using: .utf8),
                      let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                obj = parsed
            } catch {
                // ws đóng/lỗi → fail mọi pending rồi dừng loop.
                let all = drainPending(markClosed: true)
                for c in all { c.resume(throwing: error) }
                return
            }
            // Frame không có id là event — drop; response thì match theo id.
            guard let id = obj["id"] as? Int else { continue }
            lock.withLock { pending.removeValue(forKey: id) }?.resume(returning: obj)
        }
    }

    private func drainPending(markClosed: Bool) -> [CheckedContinuation<[String: Any], Error>] {
        lock.lock()
        defer { lock.unlock() }
        if markClosed { closed = true }
        let values = Array(pending.values)
        pending.removeAll()
        return values
    }
}
