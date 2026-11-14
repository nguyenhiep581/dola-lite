import Darwin
import Foundation
import WebKit

/// Import session dola.com từ profile Dola (Cici) qua CDP — Amendment A.
/// Login thủ công trong WKWebView bị dola chặn ("Sign in with Apple"), nên thay bằng:
/// rsync profile → launch "Dola Browser" phụ (DevTools port) → Storage.getCookies
/// → setCookie vào WKWebsiteDataStore → cleanup.
/// Cookie values chỉ đi qua RAM của app; không ghi disk ngoài WK store chuẩn.
enum SessionImporter {

    /// Profile nguồn đã login trên máy user.
    static var profileSource: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cici")
    }

    /// Trình duyệt phụ (Chromium-based, đi kèm Cici).
    static let browserBinary =
        "/Applications/Cici.app/Contents/Helpers/Dola Browser.app/Contents/MacOS/Dola Browser"

    static let rsyncPath = "/usr/bin/rsync"

    // MARK: - Pure helpers (unit test được)

    /// Cookie như CDP Storage.getCookies trả về (mọi field optional — CDP có thể thiếu).
    struct CDPCookie: Decodable {
        let name: String?
        let value: String?
        let domain: String?
        let path: String?
        let expires: Double?
        let httpOnly: Bool?
        let secure: Bool?
    }

    /// Map CDP cookie sang HTTPCookie; nil khi thiếu name/value/domain.
    /// Domain giữ nguyên dot/no-dot. expires <= 0 (session cookie trong CDP) → không set expires.
    static func mapToHTTPCookie(_ c: CDPCookie) -> HTTPCookie? {
        guard let name = c.name, let value = c.value, let domain = c.domain else { return nil }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: c.path ?? "/",
        ]
        if let expires = c.expires, expires > 0 {
            props[.expires] = Date(timeIntervalSince1970: expires)
        }
        if c.secure == true { props[.secure] = "TRUE" }
        // httpOnly: HTTPCookiePropertyKey không expose cờ httponly nên bỏ qua —
        // không ảnh hưởng việc WKWebView gửi cookie.
        return HTTPCookie(properties: props)
    }

    // MARK: - Pipeline (Amendment A mục 1-8)

    @MainActor
    static func importSession(into store: WKWebsiteDataStore) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DolaLite-import-\(UUID().uuidString)", isDirectory: true)
        let profileDst = tmp.appendingPathComponent("profile", isDirectory: true)
        var browser: Process?

        do {
            // 1) rsync profile sang tmp (bỏ cache/shader — không cần cho cookie).
            try await runProcess(rsyncPath, args: rsyncArgs(from: profileSource, to: profileDst))

            // 2-3) launch headless trước; nếu DevTools không lên sau 10s → relaunch không headless.
            guard let port = findFreePort() else { throw DolaError.notLoggedIn }
            browser = try launchBrowser(profile: profileDst, port: port, headless: true)
            var wsURL = await pollDevToolsURL(port: port, timeout: 10)
            if wsURL == nil {
                await stopProcess(browser!)
                browser = try launchBrowser(profile: profileDst, port: port, headless: false)
                wsURL = await pollDevToolsURL(port: port, timeout: 20)
            }
            guard let ws = wsURL else { throw DolaError.notLoggedIn }

            // 4-5) một ws duy nhất: Storage.getCookies → Browser.close.
            let cookies = try await cdpFetchCookiesAndClose(wsURL: ws)

            // 6) lọc dola.com → setCookie vào WK store (không log giá trị cookie).
            var imported = 0
            for c in cookies where c.domain?.contains("dola.com") == true {
                if let http = mapToHTTPCookie(c) {
                    await store.httpCookieStore.setCookie(http)
                    imported += 1
                }
            }
            if imported == 0 { throw DolaError.notLoggedIn }  // profile chưa login
        } catch {
            if let b = browser { await stopProcess(b) }      // 7) đợi exit (≤5s) rồi rm
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        // 7) cleanup thành công: Browser.close đã gửi trong cdpFetchCookiesAndClose.
        if let b = browser { await stopProcess(b) }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Process helpers

    static func rsyncArgs(from src: URL, to dst: URL) -> [String] {
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

    static func runProcess(_ path: String, args: [String]) async throws {
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
                        domain: "SessionImporter", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(path) exited \(proc.terminationStatus)"]))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    static func launchBrowser(profile: URL, port: Int, headless: Bool) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: browserBinary)
        var args = [
            "--user-data-dir=\(profile.path)",
            "--saman-from-chat=\(getpid())",
            "--remote-debugging-port=\(port)",
            "--no-first-run",
        ]
        if headless { args.append("--headless=new") }
        args.append("about:blank")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Đợi process thoát tối đa 5s (Browser.close đã gửi); không thì terminate —
    /// chỉ process mình spawn. Poll bằng Task.sleep để không block main thread.
    static func stopProcess(_ p: Process) async {
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

    // MARK: - Network helpers

    /// Tìm port còn tự do trong 9300...9399 bằng bind thử trên loopback.
    static func findFreePort() -> Int? {
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
    static func pollDevToolsURL(port: Int, timeout: TimeInterval) async -> URL? {
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

    /// Mở ws tới browser-level endpoint: gửi Storage.getCookies, nhận cookies[],
    /// rồi gửi Browser.close và đóng ws. Timeout tổng 10s cho mỗi chiều.
    static func cdpFetchCookiesAndClose(wsURL: URL) async throws -> [CDPCookie] {
        let ws = URLSession.shared.webSocketTask(with: wsURL)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }
        try await ws.send(.string(#"{"id":1,"method":"Storage.getCookies"}"#))
        let msg = try await withTimeout(10) { try await ws.receive() }
        guard case .string(let text) = msg else { throw DolaError.notLoggedIn }
        struct Envelope: Decodable {
            struct Result: Decodable { let cookies: [CDPCookie]? }
            let result: Result?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else {
            throw DolaError.notLoggedIn
        }
        // Browser.close (best-effort) — process exit do stopProcess lo.
        try? await ws.send(.string(#"{"id":2,"method":"Browser.close"}"#))
        return envelope.result?.cookies ?? []
    }

    /// Race op với timeout — trả lỗi URLError.timedOut nếu op chậm hơn `seconds`.
    static func withTimeout<T>(_ seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
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
