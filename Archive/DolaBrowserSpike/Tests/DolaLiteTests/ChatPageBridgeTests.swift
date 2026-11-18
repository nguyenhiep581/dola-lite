import Testing
@testable import DolaLite

@Suite struct ChatPageBridgeTests {
    @Test func probeScriptReturnsEditorInfoJSON() {
        let js = ChatPageBridge.probeScript
        #expect(js.contains("editorTag"))
        #expect(js.contains("botSelector"))
    }

    /// jsString là helper escape dùng khi cần nhúng chuỗi vào JS (dù send path giờ
    /// gõ thật qua NSResponder nên prompt không còn nhúng vào script).
    @Test func jsStringEscapesForEmbedding() {
        let s = "line1\nline2 \"quoted\""
        let escaped = ChatPageBridge.jsString(s)
        #expect(!escaped.contains("line1\nline2 \"quoted\""), "chuỗi gốc phải được escape")
        #expect(escaped.contains("\\n"))
    }

    @Test func parsePollResultExtractsTextAndDone() throws {
        let json = #"{"exists":true,"text":"Con cáo","stable":false,"found":true}"#
        let r = try ChatPageBridge.parsePollResult(json)
        #expect(r.text == "Con cáo")
        #expect(!r.stable)
        #expect(r.found)
    }

    @Test func parsePollResultBotNotAppearedYet() throws {
        let r = try ChatPageBridge.parsePollResult(#"{"exists":false,"text":"","stable":false,"found":false}"#)
        #expect(!r.found)
    }

    @Test func botSelectorCandidatesOrdered() {
        #expect(ChatPageBridge.botSelectors.first == ".message-item-robot")
    }

    /// Regression: selector trong JS sinh ra phải là chuỗi sạch, không bọc thêm nháy đơn —
    /// querySelectorAll("'.x'") throw SyntaxError trong trang (verify bằng engine thật).
    @Test func generatedJSSelectorsAreNotQuoteWrapped() {
        let dq_sq = "\u{22}\u{27}" // `" '`
        #expect(!ChatPageBridge.probeScript.contains(dq_sq))
        #expect(!ChatPageBridge.focusAndBaselineScript.contains(dq_sq))
        #expect(ChatPageBridge.probeScript.contains("\u{22}.message-item-robot\u{22}"))
    }

    /// Fix round 6: send path chỉ focus + baseline — KHÔNG set text/synthetic events
    /// (bị dola chặn); text được gõ thật qua NSResponder (typePrompt).
    @Test func focusAndBaselineScriptFocusesOnly() {
        let js = ChatPageBridge.focusAndBaselineScript
        #expect(js.contains("__dolaLite"))
        #expect(js.contains("focus()"))
        #expect(js.contains("FOCUSED"))
        #expect(!js.contains("SENT_"))
        #expect(!js.contains("setter.call"))
        #expect(!js.contains("KeyboardEvent"))
        #expect(!js.contains("InputEvent"))
        #expect(!js.contains(".click()"))
    }
}
