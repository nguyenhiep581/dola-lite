import JavaScriptCore
import Testing
@testable import DolaLite

@Suite struct EditorReadinessTests {
    // DOM boundary fixture: the live page first renders a textarea, then a hidden
    // ProseMirror, and finally replaces the textarea with the visible editor.
    private func context(readyState: String = "complete", visible: Bool = true, focusWorks: Bool = true) -> JSContext {
        let context = JSContext()!
        context.evaluateScript("""
        var window = this;
        var now = 0;
        var performance = {now: () => now};
        var textarea = {focus: () => { document.activeElement = textarea; }};
        var editor = {
          isConnected: true, isContentEditable: true,
          getBoundingClientRect: () => ({width: 448, height: 24}),
          focus: () => { if (\(focusWorks)) document.activeElement = editor; }
        };
        var document = {
          readyState: '\(readyState)', activeElement: null,
          querySelector: s => s === 'textarea' ? textarea : editor,
          querySelectorAll: s => s.includes('contenteditable') ? [editor] : [],
          hasFocus: () => true
        };
        var getComputedStyle = () => ({display:'block', visibility:'\(visible ? "visible" : "hidden")'});
        """)
        return context
    }

    @Test func pollingFindsFirstReplyInInitiallyEmptyChat() {
        let c = context()
        _ = c.evaluateScript(ChatPageBridge.focusAndBaselineScript)
        c.evaluateScript("now = 3000")
        _ = c.evaluateScript(ChatPageBridge.focusAndBaselineScript)
        c.evaluateScript("""
        document.querySelectorAll = s => s === '.message-item-robot' ? [{innerText:'Xin chào'}] : [];
        """)
        let result = c.evaluateScript(ChatPageBridge.pollScript)?.toString() ?? ""
        let poll = try? ChatPageBridge.parsePollResult(result)
        #expect(poll?.found == true)
        #expect(poll?.text == "Xin chào")
    }

    @Test func loadingPageDoesNotReportReady() {
        let c = context(readyState: "interactive")
        #expect(c.evaluateScript(ChatPageBridge.focusAndBaselineScript)?.toString() != "FOCUSED")
    }

    @Test func hiddenEditorDoesNotFallBackToTemporaryTextarea() {
        let c = context(visible: false)
        #expect(c.evaluateScript(ChatPageBridge.focusAndBaselineScript)?.toString() != "FOCUSED")
    }

    @Test func focusMustActuallyReachEditor() {
        let c = context(focusWorks: false)
        _ = c.evaluateScript(ChatPageBridge.focusAndBaselineScript)
        c.evaluateScript("now = 3000")
        #expect(c.evaluateScript(ChatPageBridge.focusAndBaselineScript)?.toString() != "FOCUSED")
    }

    @Test func waitsForSameVisibleEditorToSettle() {
        let c = context()
        #expect(c.evaluateScript(ChatPageBridge.focusAndBaselineScript)?.toString() != "FOCUSED")
        c.evaluateScript("now = 3000")
        #expect(c.evaluateScript(ChatPageBridge.focusAndBaselineScript)?.toString() == "FOCUSED")
        #expect(c.evaluateScript("document.activeElement === editor")?.toBool() == true)
        c.evaluateScript("editor = {...editor}; now = 3100")
        #expect(c.evaluateScript(ChatPageBridge.focusAndBaselineScript)?.toString() != "FOCUSED")
    }
}
