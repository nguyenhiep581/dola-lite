import AppKit
import Testing
@testable import DolaLite

@Suite struct SelectionTests {
    private func selection(_ text: String = "Hello", pid: pid_t = 42, range: NSRange? = NSRange(location: 0, length: 5)) -> SelectionSnapshot {
        SelectionSnapshot(text: text, bounds: NSRect(x: 20, y: 30, width: 80, height: 20), sourcePID: pid, range: range)
    }

    @Test func repeatedPollingDoesNotPostponeStableSelection() {
        var debounce = SelectionDebouncer(interval: 0.3)
        let value = selection()
        #expect(debounce.observe(value, at: 0) == nil)
        #expect(debounce.observe(value, at: 0.1) == nil)
        #expect(debounce.observe(value, at: 0.2) == nil)
        #expect(debounce.observe(value, at: 0.31)?.snapshot == value)
        #expect(debounce.observe(value, at: 0.8) == nil)
    }

    @Test func changingSelectionCoalescesAndClearingCancelsPending() {
        var debounce = SelectionDebouncer(interval: 0.3)
        #expect(debounce.observe(selection("first"), at: 0) == nil)
        #expect(debounce.observe(selection("second"), at: 0.2) == nil)
        #expect(debounce.observe(selection("second"), at: 0.4) == nil)
        #expect(debounce.observe(nil, at: 0.45) == nil)
        #expect(debounce.observe(selection("second"), at: 0.6) == nil)
        #expect(debounce.observe(selection("second"), at: 0.91)?.snapshot?.text == "second")
        let cleared = debounce.observe(nil, at: 1)
        #expect(cleared != nil)
        #expect(cleared?.snapshot == nil)
        #expect(debounce.observe(nil, at: 1.1) == nil)
    }

    @Test func appChangeClearsBeforePublishingNewSelection() {
        var debounce = SelectionDebouncer(interval: 0.3)
        _ = debounce.observe(selection(), at: 0)
        _ = debounce.observe(selection(), at: 0.31)
        let otherApp = selection(pid: 99)
        let change = debounce.observe(otherApp, at: 0.4)
        #expect(change != nil)
        #expect(change?.snapshot == nil)
        #expect(debounce.observe(otherApp, at: 0.71)?.snapshot == otherApp)
    }

    @Test func sameTextAtDifferentRangeIsNewSelection() {
        let first = selection()
        let second = selection(range: NSRange(location: 25, length: 5))
        #expect(first != second)
        var debounce = SelectionDebouncer(interval: 0.3)
        _ = debounce.observe(first, at: 0)
        _ = debounce.observe(first, at: 0.31)
        #expect(debounce.observe(second, at: 0.4) == nil)
        #expect(debounce.observe(second, at: 0.71)?.snapshot == second)
    }

    @Test func filterCountsGraphemesAndPreservesEmoji() {
        #expect(SelectionFilter.sanitize(" \n ") == nil)
        #expect(SelectionFilter.sanitize("é") == nil)
        #expect(SelectionFilter.sanitize(" 👨‍👩‍👧‍👦🇻🇳a ", maximum: 2) == "👨‍👩‍👧‍👦🇻🇳")
        #expect(SelectionFilter.sanitize("  Hello\nworld  ") == "Hello\nworld")
        #expect(SelectionFilter.sanitize(String(repeating: "ộ", count: 10_001))?.count == 10_000)
    }
}
