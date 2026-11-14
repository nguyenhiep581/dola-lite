import Testing
@testable import DolaLite

@Suite struct ChatPageBridgeTests {
    @Test func probeScriptReturnsEditorInfoJSON() {
        let js = ChatPageBridge.probeScript
        #expect(js.contains("editorTag"))
        #expect(js.contains("botSelector"))
    }

    @Test func sendScriptEmbedsEscapedPrompt() {
        let js = ChatPageBridge.sendScript(prompt: "line1\nline2 \"quoted\"")
        #expect(!js.contains("line1\nline2 \"quoted\""), "prompt phải được escape/JSON-embedded")
        #expect(js.contains("\\n"))
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
        #expect(!ChatPageBridge.sendScript(prompt: "x").contains(dq_sq))
        #expect(ChatPageBridge.probeScript.contains("\u{22}.message-item-robot\u{22}"))
    }
}
