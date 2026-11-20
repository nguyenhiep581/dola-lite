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

    @Test func clearGracePreservesBriefDipAndTransientSamePIDWithoutDroppingPill() {
        var debounce = SelectionDebouncer(interval: 0.3, clearInterval: 0.25)
        let first = selection()
        #expect(debounce.observe(.selection(first), at: 0) == nil)
        #expect(debounce.observe(.selection(first), at: 0.31)?.snapshot == first)

        // Brief noSelection dip (e.g., Jira DOM re-render) < clearInterval does NOT clear.
        #expect(debounce.observe(.noSelection, at: 0.4) == nil)
        #expect(debounce.observe(.noSelection, at: 0.55) == nil)
        // Re-observed selection stays active without re-publishing.
        #expect(debounce.observe(.selection(first), at: 0.6) == nil)
        #expect(debounce.published == first)

        // Brief transient AX error from same app PID (< transientGraceInterval 1.2s) preserves active pill...
        #expect(debounce.observe(.transientError(sourcePID: 42), at: 0.7) == nil)
        #expect(debounce.observe(.transientError(sourcePID: 42), at: 1.5) == nil)
        #expect(debounce.published == first)
        // ...while a sustained same-PID stall >= 1.2s clears cleanly so no ghost pill remains stuck.
        #expect(debounce.observe(.transientError(sourcePID: 42), at: 1.95)?.snapshot == nil)
        #expect(debounce.published == nil)

        // Switching to a different app PID that returns transient AX errors clears after interval grace period.
        #expect(debounce.observe(.selection(first), at: 2.0) == nil)
        #expect(debounce.observe(.selection(first), at: 2.31)?.snapshot == first)
        #expect(debounce.observe(.transientError(sourcePID: 99), at: 2.4) == nil)
        #expect(debounce.observe(.transientError(sourcePID: 99), at: 2.71)?.snapshot == nil)
        #expect(debounce.published == nil)

        // Sustained noSelection clears once >= clearInterval.
        #expect(debounce.observe(.selection(first), at: 3.0) == nil)
        #expect(debounce.observe(.selection(first), at: 3.31)?.snapshot == first)
        #expect(debounce.observe(.noSelection, at: 3.4) == nil)
        #expect(debounce.observe(.noSelection, at: 3.66)?.snapshot == nil)
        #expect(debounce.published == nil)
    }

    @Test func subpixelBoundsJitterDoesNotResetDebounceOrRepublish() {
        var debounce = SelectionDebouncer(interval: 0.3, clearInterval: 0.25)
        let base = SelectionSnapshot(text: "Jira issue", bounds: NSRect(x: 100, y: 200, width: 120, height: 18), sourcePID: 42, range: nil)
        let jittered = SelectionSnapshot(text: "Jira issue", bounds: NSRect(x: 101.2, y: 199.0, width: 121.5, height: 18.5), sourcePID: 42, range: nil)
        #expect(debounce.observe(.selection(base), at: 0) == nil)
        #expect(debounce.observe(.selection(jittered), at: 0.15) == nil)
        // Did not reset timer at 0.15, so publishes at 0.31.
        let published = debounce.observe(.selection(jittered), at: 0.31)?.snapshot
        #expect(published == jittered)
        #expect(published?.isEquivalent(to: base) == true)
        // Further subpixel jitter after publication does not re-publish.
        #expect(debounce.observe(.selection(base), at: 0.5) == nil)
    }

    @Test func boundsSanitizerConvertsValidRectsAndRejectsChromiumPlaceholders() {
        let valid = SelectionBoundsSanitizer.sanitize(axRect: CGRect(x: 200, y: 100, width: 140, height: 22), primaryTop: 900)
        #expect(valid == NSRect(x: 200, y: 778, width: 140, height: 22))

        // Rejects Chromium (0, 0) placeholder, extreme sr-only, empty, and non-finite rects.
        #expect(SelectionBoundsSanitizer.sanitize(axRect: CGRect(x: 0, y: 0, width: 80, height: 18), primaryTop: 900) == nil)
        #expect(SelectionBoundsSanitizer.sanitize(axRect: CGRect(x: 0.5, y: 0.5, width: 80, height: 18), primaryTop: 900) == nil)
        #expect(SelectionBoundsSanitizer.sanitize(axRect: CGRect(x: -9999, y: 200, width: 20, height: 18), primaryTop: 900) == nil)
        #expect(SelectionBoundsSanitizer.sanitize(axRect: CGRect(x: 200, y: 35000, width: 20, height: 18), primaryTop: 900) == nil)
        #expect(SelectionBoundsSanitizer.sanitize(axRect: .zero, primaryTop: 900) == nil)
        #expect(SelectionBoundsSanitizer.sanitize(axRect: .null, primaryTop: 900) == nil)
        #expect(SelectionBoundsSanitizer.sanitize(axRect: CGRect(x: CGFloat.nan, y: 100, width: 50, height: 20), primaryTop: 900) == nil)
    }

    @Test func chromiumDetectorMatchesBrowsersAndElectronOnly() throws {
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.google.Chrome", bundleURL: nil))
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.microsoft.edgemac", bundleURL: nil))
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "company.thebrowser.Browser", bundleURL: nil))
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "company.thebrowser.dia", bundleURL: nil))
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.operasoftware.Opera", bundleURL: nil))
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.brave.Browser", bundleURL: nil))
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.microsoft.VSCode", bundleURL: nil))

        #expect(!ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.apple.Safari", bundleURL: nil))
        #expect(!ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.apple.finder", bundleURL: nil))
        #expect(!ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.apple.dt.Xcode", bundleURL: nil))
        #expect(!ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.apple.Notes", bundleURL: nil))
        #expect(!ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.apple.MediaPlayer", bundleURL: nil))
        #expect(!ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.apple.diagnostic", bundleURL: nil))

        let tempApp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DolaLite-ElectronDetect-\(UUID().uuidString).app", isDirectory: true)
        let electronFW = tempApp.appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: electronFW, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempApp) }
        #expect(ChromiumAccessibilityDetector.shouldEnableEnhancedAX(bundleIdentifier: "com.example.CustomDesktop", bundleURL: tempApp))
    }
}
