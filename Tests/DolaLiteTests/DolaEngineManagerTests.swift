import Foundation
import Testing
@testable import DolaLite

/// Pure helpers của engine CDP (Amendment B) — format lock với spec:
/// Runtime.evaluate / Input.insertText / Input.dispatchKeyEvent(Enter).
@Suite struct DolaEngineManagerTests {

    private func json(_ obj: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: CDP params builders

    @Test func evaluateParamsCarryExpressionAndReturnByValue() throws {
        let s = try json(DolaEngineManager.evaluateParams("(() => 1)()"))
        #expect(s == #"{"expression":"(() => 1)()","returnByValue":true}"#)
    }

    @Test func insertTextParamsJSONEscapesText() throws {
        let s = try json(DolaEngineManager.insertTextParams("line1\nline2 \"quoted\""))
        // Newline → \n, quote → \" (escape chuẩn JSON, engine parse lại đúng nguyên văn)
        #expect(s == #"{"text":"line1\nline2 \"quoted\""}"#)
    }

    @Test func enterKeyParamsMatchProvenSpikeFormat() throws {
        let down = try json(DolaEngineManager.enterKeyParams(type: "keyDown"))
        #expect(down == #"{"code":"Enter","key":"Enter","nativeVirtualKeyCode":13,"type":"keyDown","windowsVirtualKeyCode":13}"#)
        let up = try json(DolaEngineManager.enterKeyParams(type: "keyUp"))
        #expect(up == #"{"code":"Enter","key":"Enter","nativeVirtualKeyCode":13,"type":"keyUp","windowsVirtualKeyCode":13}"#)
    }

    // MARK: Envelope builder

    @Test func envelopePlacesIdMethodParams() throws {
        let data = DolaEngineManager.envelope(id: 7, method: "Input.insertText", params: ["text": "hi"])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["id"] as? Int == 7)
        #expect(obj["method"] as? String == "Input.insertText")
        #expect((obj["params"] as? [String: Any])?["text"] as? String == "hi")
    }

    @Test func envelopeWithoutParamsOmitsKey() throws {
        let data = DolaEngineManager.envelope(id: 2, method: "Browser.close", params: nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["params"] == nil)
        #expect(obj.count == 2)
    }

    @Test func envelopeEscapesNewlineInsideExpression() throws {
        let data = DolaEngineManager.envelope(
            id: 1, method: "Runtime.evaluate",
            params: DolaEngineManager.evaluateParams("a\nb"))
        let s = String(decoding: data, as: UTF8.self)
        #expect(s.contains("\\n"))   // escape JSON, không phải newline thô
        #expect(!s.contains("\n"))
    }

    // MARK: Response parse

    @Test func evaluateResultValueReadsNestedResultDotValue() {
        let resp: [String: Any] = ["result": ["result": ["type": "string", "value": "FOCUSED"]]]
        #expect(DolaEngineManager.evaluateResultValue(resp) == "FOCUSED")
    }

    @Test func evaluateResultValueNilForErrorOrNonStringValue() {
        #expect(DolaEngineManager.evaluateResultValue(["error": ["message": "x"]]) == nil)
        #expect(DolaEngineManager.evaluateResultValue(["result": ["result": ["type": "object"]]]) == nil)
        #expect(DolaEngineManager.evaluateResultValue(["result": [:]]) == nil)
    }

    @Test func cdpErrorMessageExtracted() {
        let resp: [String: Any] = ["id": 3, "error": ["code": -32000, "message": "Cannot find context"]]
        #expect(DolaEngineManager.cdpErrorMessage(resp) == "Cannot find context")
        #expect(DolaEngineManager.cdpErrorMessage(["id": 4, "result": [:]]) == nil)
    }

    // MARK: openChat endpoint

    /// Fix round 1 (Task 2B): fork chỉ nhận dạng query legacy KHÔNG tên param —
    /// `?url=` bị bỏ qua → tab about:blank. Query phải là chính URL đã encode.
    @Test func newTabURLUsesLegacyQueryWithoutParamName() {
        let url = DolaEngineManager.newTabURL(port: 9300, chat: Config.chatURL)
        #expect(url.absoluteString == "http://127.0.0.1:9300/json/new?https%3A%2F%2Fwww.dola.com%2Fchat%2F")
        #expect(!url.absoluteString.contains("url="))
    }

    // MARK: rsync args (regression giữ từ SessionImporterTests)

    /// Fix round 4: profile copy PHẢI loại Singleton*/RunningChromeVersion — symlinks
    /// Singleton trỏ sang socket của browser chính, làm browser phụ exit như duplicate.
    @Test func rsyncArgsExcludeSingletonSymlinksAndCaches() {
        let args = DolaEngineManager.rsyncArgs(
            from: URL(fileURLWithPath: "/tmp/src"), to: URL(fileURLWithPath: "/tmp/dst"))
        var pairs: [String] = []
        for (i, a) in args.enumerated() where i > 0 && args[i - 1] == "--exclude" {
            pairs.append(a)
        }
        #expect(pairs.contains("Singleton*"))
        #expect(pairs.contains("RunningChromeVersion"))
        #expect(pairs.contains("Default/Code Cache"))   // space trong pattern an toàn trong args array
    }

    @Test func rsyncArgsKeepArchiveFlagAndTrailingSlashes() {
        let args = DolaEngineManager.rsyncArgs(
            from: URL(fileURLWithPath: "/tmp/src"), to: URL(fileURLWithPath: "/tmp/dst"))
        #expect(args.first == "-a")
        #expect(args.contains("/tmp/src/"))
        #expect(args.last == "/tmp/dst/")
    }
}
