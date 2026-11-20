import AppKit
import Testing
@testable import DolaLite

@Suite struct UIPlacementTests {
    @Test func secondaryDisplayWithNegativeCoordinatesIsRespected() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1280, y: 0, width: 1280, height: 1024)]
        let pill = PanelPlacement.pillFrame(size: NSSize(width: 298, height: 40),
            anchor: NSRect(x: -900, y: 300, width: 100, height: 20), mouseLocation: .zero, screens: screens)
        #expect(screens[1].contains(pill))
        #expect(pill.maxY == 288)

        let result = PanelPlacement.resultFrame(size: NSSize(width: 390, height: 350),
            anchor: NSRect(x: -900, y: 500, width: 298, height: 40), mouseLocation: .zero, screens: screens)
        #expect(screens[1].contains(result))
        #expect(result.maxY == 540)
    }

    @Test func pillPlacementPreservesItsCompactRequestedSize() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = PanelPlacement.pillFrame(size: NSSize(width: 298, height: 40), anchor: NSRect(x: 400, y: 300, width: 80, height: 20),
                                             mouseLocation: .zero, screens: [screen])
        #expect(frame.size == NSSize(width: 298, height: 40))
        #expect(screen.contains(frame))
    }

    @Test func nearTopAndBottomEdgesClampHorizontalAndVerticalEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let nearTop = PanelPlacement.pillFrame(size: NSSize(width: 298, height: 40),
            anchor: NSRect(x: 1420, y: 850, width: 20, height: 20), mouseLocation: .zero, screens: [screen])
        #expect(nearTop.maxX == 1432)
        #expect(nearTop.maxY == 838)
        #expect(screen.contains(nearTop))
    }

    @Test func missingBoundsUsesNearestMouseDisplayAndSmallScreensFit() {
        let small = NSRect(x: 0, y: -200, width: 300, height: 250)
        let smallResult = PanelPlacement.resultFrame(size: NSSize(width: 390, height: 350), anchor: nil,
            mouseLocation: NSPoint(x: 80, y: -80), screens: [small])
        #expect(small.contains(smallResult))
        #expect(smallResult.width == 284)
        #expect(smallResult.height == 234)

        // Cursor slightly outside visibleFrame (e.g., menu bar / Dock on secondary display) still picks secondary display.
        let main = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let secondaryVisible = NSRect(x: -1280, y: 40, width: 1280, height: 960)
        let dockCursor = NSPoint(x: -640, y: 12)
        let onSecondary = PanelPlacement.pillFrame(size: NSSize(width: 298, height: 40), anchor: nil,
            mouseLocation: dockCursor, screens: [main, secondaryVisible])
        #expect(secondaryVisible.contains(onSecondary))
    }

    @Test func restoredPanelSizeAndPartialOrZeroAnchorsAreClampedProperly() {
        let screen = NSRect(x: -800, y: -100, width: 800, height: 600)
        let frame = PanelPlacement.resultFrame(size: NSSize(width: 1200, height: 900),
                                              anchor: NSRect(x: -600, y: 100, width: 20, height: 20),
                                              mouseLocation: .zero, screens: [screen])
        #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
        #expect(frame.width == 784)
        #expect(frame.height == 584)

        // Zero-size anchor on screen stays valid instead of being rejected by zero-area intersects.
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let zeroAnchor = NSRect(x: 400, y: 500, width: 0, height: 0)
        let pillFromZero = PanelPlacement.pillFrame(size: NSSize(width: 298, height: 40), anchor: zeroAnchor,
            mouseLocation: NSPoint(x: 1200, y: 200), screens: [main])
        #expect(pillFromZero.midX == 400)
        #expect(pillFromZero.maxY == 488)

        // Partially offscreen anchor stays on-screen and clamps pill inside margin.
        let partial = NSRect(x: -50, y: 400, width: 120, height: 20)
        let pillFromPartial = PanelPlacement.pillFrame(size: NSSize(width: 298, height: 40), anchor: partial,
            mouseLocation: NSPoint(x: 1000, y: 200), screens: [main])
        #expect(pillFromPartial.minX == 8)
        #expect(pillFromPartial.maxY == 388)
    }

    @Test func movedPanelIsClampedAndKeepsMinimumSize() {
        let screen = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let frame = PanelPlacement.clampedFrame(NSRect(x: 900, y: -300, width: 200, height: 120), screens: [screen])
        #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
        #expect(frame.width == 320)
        #expect(frame.height == 240)
    }

    @Test func resizingTracksTheBottomRightHandleInScreenCoordinates() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = NSRect(x: 100, y: 100, width: 390, height: 350)
        let draggedUp = PanelPlacement.resizedFrame(initial, delta: NSPoint(x: 20, y: 40), screens: [screen])
        #expect(draggedUp.width == 410)
        #expect(draggedUp.height == 310)
        #expect(draggedUp.minY == 140)
        #expect(draggedUp.maxY == initial.maxY)

        let draggedDown = PanelPlacement.resizedFrame(initial, delta: NSPoint(x: 0, y: -40), screens: [screen])
        #expect(draggedDown.height == 390)
        #expect(draggedDown.minY == 60)
        #expect(draggedDown.maxY == initial.maxY)

        // Dragging upward past minimumSize.height must clamp height without pushing the top edge upward.
        let clampedMin = PanelPlacement.resizedFrame(initial, delta: NSPoint(x: -200, y: 200), screens: [screen])
        #expect(clampedMin.width == 320)
        #expect(clampedMin.height == 240)
        #expect(clampedMin.maxY == initial.maxY)

        // Dragging past right/bottom edges or across a monitor seam keeps top-left anchored on the starting screen.
        let dualScreens = [screen, NSRect(x: 1440, y: 0, width: 1440, height: 900)]
        let clampedEdge = PanelPlacement.resizedFrame(initial, delta: NSPoint(x: 2500, y: -500), screens: dualScreens)
        #expect(clampedEdge.minX == initial.minX)
        #expect(clampedEdge.maxY == initial.maxY)
        #expect(clampedEdge.maxX == 1432)
        #expect(clampedEdge.minY == 8)
    }

    @Test func pillPlacementPrefersBelowSelectionToAvoidAskRovoAndHandlesEdgeCases() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pillSize = NSSize(width: 298, height: 40)

        // Default placement sits below selection (maxY == anchor.minY - 12), avoiding Jira's Ask Rovo bar above.
        let anchor = NSRect(x: 500, y: 400, width: 120, height: 22)
        let below = PanelPlacement.pillFrame(size: pillSize, anchor: anchor, mouseLocation: NSPoint(x: 610, y: 405), screens: [screen])
        #expect(below.maxY == anchor.minY - 12)
        #expect(below.midX == anchor.midX)
        #expect(screen.contains(below))

        // Near bottom edge: flips above selection instead of clipping below taskbar/dock.
        let lowAnchor = NSRect(x: 500, y: 20, width: 120, height: 22)
        let flippedAbove = PanelPlacement.pillFrame(size: pillSize, anchor: lowAnchor, mouseLocation: NSPoint(x: 550, y: 30), screens: [screen])
        #expect(flippedAbove.minY == lowAnchor.maxY + 12)
        #expect(screen.contains(flippedAbove))

        // Off-screen anchor is rejected and falls back cleanly to cursor location.
        let offscreen = NSRect(x: -4000, y: 400, width: 100, height: 20)
        let fallback = PanelPlacement.pillFrame(size: pillSize, anchor: offscreen, mouseLocation: NSPoint(x: 700, y: 500), screens: [screen])
        #expect(fallback.midX == 700)
        #expect(fallback.maxY == 488.0)

        // Tall multi-paragraph selection collapses near nearby mouse pointer...
        let tall = NSRect(x: 300, y: 120, width: 500, height: 420)
        let mouseNearBottom = NSPoint(x: 640, y: 160)
        let nearMouse = PanelPlacement.pillFrame(size: pillSize, anchor: tall, mouseLocation: mouseNearBottom, screens: [screen])
        #expect(nearMouse.midX == 640.5)
        #expect(nearMouse.maxY == (mouseNearBottom.y - 12) - 12)

        // ...while keyboard selection with faraway cursor preserves the valid on-screen anchor.
        let keyboardSelection = PanelPlacement.pillFrame(size: pillSize, anchor: tall, mouseLocation: NSPoint(x: 1350, y: 850), screens: [screen])
        #expect(keyboardSelection.midX == tall.midX)
        #expect(keyboardSelection.maxY == tall.minY - 12)
    }

    @Test func resultFrameOpensInPlaceAtPillTopCenterAndClampsSmoothly() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let resultSize = NSSize(width: 390, height: 350)

        let pill = NSRect(x: 500, y: 600, width: 298, height: 40)
        let opened = PanelPlacement.resultFrame(size: resultSize, anchor: pill, mouseLocation: .zero, screens: [screen])
        #expect(opened.maxY == pill.maxY)
        #expect(opened.midX == pill.midX)
        #expect(opened.size == resultSize)

        // Near bottom edge: slides up only enough to remain onscreen with 8pt margin, staying centered on pill X.
        let lowPill = NSRect(x: 500, y: 100, width: 298, height: 40)
        let clamped = PanelPlacement.resultFrame(size: resultSize, anchor: lowPill, mouseLocation: .zero, screens: [screen])
        #expect(clamped.minY == 8)
        #expect(clamped.midX == lowPill.midX)

        // Near right edge: clamps X cleanly inside screen margin.
        let rightPill = NSRect(x: 1120, y: 600, width: 298, height: 40)
        let rightClamped = PanelPlacement.resultFrame(size: resultSize, anchor: rightPill, mouseLocation: .zero, screens: [screen])
        #expect(rightClamped.maxX == 1432)
        #expect(rightClamped.maxY == rightPill.maxY)
    }

    @Test func historyTrayKeepsMinimumSpaceWhenPanelCannotGrow() {
        #expect(PanelPlacement.historyTrayHeight(originalHeight: 760, expandedHeight: 760) == 96)
        #expect(PanelPlacement.historyTrayHeight(originalHeight: 350, expandedHeight: 530) == 164)
        #expect(PanelPlacement.historyTrayHeight(originalHeight: 350, expandedHeight: 900) == 170)
    }

    @Test @MainActor func resultPanelSizePreferenceRoundTrips() {
        let defaults = InMemoryPanelDefaults()
        let store = ResultPanelSizeStore(defaults: defaults)
        #expect(store.load(default: NSSize(width: 390, height: 350)) == NSSize(width: 390, height: 350))
        store.save(NSSize(width: 680, height: 520))
        #expect(store.load(default: NSSize(width: 390, height: 350)) == NSSize(width: 680, height: 520))
        store.save(NSSize(width: CGFloat.infinity, height: 100))
        #expect(store.load(default: NSSize(width: 390, height: 350)) == NSSize(width: 680, height: 520))
    }

    @Test @MainActor func markdownDisplaysBasicFormattingWithoutChangingSource() {
        let source = "## Tiêu đề\n- **xin chào** `value`\n```swift\nlet x = 1\n```"
        let rendered = MarkdownLite.attributed(source)
        #expect(rendered.string.contains("• xin chào value"))
        #expect(rendered.string.contains("let x = 1"))
        #expect(!rendered.string.contains("**"))
        #expect(source.contains("**xin chào**"))
    }

    @Test @MainActor func resultPanelWrapsLongTextWithoutHorizontalOverflow() {
        _ = NSApplication.shared
        let result = ResultPanel()
        result.show(skill: .translate, near: nil)
        result.append(String(repeating: "Đoạn văn bản dài để kiểm tra việc xuống dòng tự nhiên của panel kết quả. ", count: 12))
        result.finish()
        result.contentView?.layoutSubtreeIfNeeded()

        func firstSubview(of view: NSView, matching check: (NSView) -> Bool) -> NSView? {
            if check(view) { return view }
            for subview in view.subviews {
                if let found = firstSubview(of: subview, matching: check) { return found }
            }
            return nil
        }
        let scrollView = result.contentView.flatMap { firstSubview(of: $0, matching: { $0 is NSScrollView }) } as? NSScrollView
        let textView = scrollView?.documentView as? NSTextView
        #expect(scrollView != nil)
        #expect(textView != nil)
        if let scrollView, let textView {
            // Wrapped text keeps the document width at the visible width…
            #expect(textView.frame.width <= scrollView.contentView.bounds.width + 0.5)
            // …and grows vertically instead of sideways.
            #expect(textView.frame.height > 120)
        }
        result.dismiss()
    }

    @Test @MainActor func resultHistoryExpandsInsideTheSamePanelAndRestoresItsSize() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DolaLite-InlineHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let entry = HistoryEntry(skill: .summarize, model: "fixture-model", sourceText: "Source preview",
                                 resultText: "Historical summary")
        try store.add(entry)

        let result = ResultPanel(historyStore: store)
        result.show(skill: .translate, near: nil)
        result.append("Current result")
        result.finish()
        let originalFrame = result.frame

        guard let historyButton = findButton(in: result.contentView!, label: "Lịch sử") else {
            Issue.record("Expected a history button in the result panel")
            result.dismiss()
            return
        }
        historyButton.performClick(historyButton)
        #expect(result.isVisible)
        #expect(result.isHistoryVisible)
        #expect(result.frame.height > originalFrame.height)

        guard let historyRow = allButtons(in: result.contentView!).first(where: { $0.title.contains("Source preview") }) else {
            Issue.record("Expected the history entry below the current result")
            result.dismiss()
            return
        }
        historyRow.performClick(historyRow)
        #expect(result.fullText == "Historical summary")
        #expect(result.isHistoryVisible)
        result.toggleHistory()
        #expect(result.frame == originalFrame)
        result.dismiss()
    }

    @Test @MainActor func resultPanelHeaderDragHandleDoesNotOverlapHeaderButtons() {
        _ = NSApplication.shared
        let result = ResultPanel()
        result.show(skill: .translate, near: nil)
        result.contentView?.layoutSubtreeIfNeeded()
        defer { result.dismiss() }

        let dragHandle = result.contentView.flatMap { findView(in: $0, label: "Kéo để di chuyển cửa sổ") }
        let pinButton = result.contentView.flatMap { findButton(in: $0, label: "Giữ cửa sổ mở") }
        let copyButton = result.contentView.flatMap { findButton(in: $0, label: "Sao chép kết quả") }
        #expect(dragHandle != nil)
        #expect(pinButton != nil)
        #expect(copyButton != nil)
        if let dragHandle, let pinButton, let copyButton {
            #expect(!dragHandle.frame.intersects(pinButton.frame))
            #expect(!dragHandle.frame.intersects(copyButton.frame))
        }
    }

    @Test @MainActor func movingPanelWhileHistoryIsOpenPreservesNewPositionOnClose() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DolaLite-MoveHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        try store.add(HistoryEntry(skill: .translate, model: "fixture-model", sourceText: "Hello", resultText: "Xin chào"))

        let result = ResultPanel(historyStore: store)
        result.show(skill: .translate, near: nil)
        defer { result.dismiss() }

        result.toggleHistory()
        #expect(result.isHistoryVisible)
        #expect(result.minSize.height > 240)
        let movedOrigin = NSPoint(x: result.frame.minX + 40, y: result.frame.minY)
        result.setFrameOrigin(movedOrigin)
        let movedTop = result.frame.maxY
        let movedX = result.frame.minX

        result.toggleHistory()
        #expect(!result.isHistoryVisible)
        #expect(result.minSize.height == 240)
        #expect(abs(result.frame.minX - movedX) <= 1.0)
        #expect(abs(result.frame.maxY - movedTop) <= 1.0)
    }

    private func findView(in view: NSView, label: String) -> NSView? {
        if view.accessibilityLabel() == label { return view }
        for subview in view.subviews {
            if let found = findView(in: subview, label: label) { return found }
        }
        return nil
    }

    private func findButton(in view: NSView, label: String) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityLabel() == label { return button }
        for subview in view.subviews {
            if let found = findButton(in: subview, label: label) { return found }
        }
        return nil
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        var buttons = (view as? NSButton).map { [$0] } ?? []
        buttons.append(contentsOf: view.subviews.flatMap { allButtons(in: $0) })
        return buttons
    }
}

@MainActor
private final class InMemoryPanelDefaults: UserDefaults {
    private var storage: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value }
}
