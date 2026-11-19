import AppKit
import Testing
@testable import DolaLite

@Suite struct UIPlacementTests {
    @Test func secondaryDisplayWithNegativeCoordinatesIsRespected() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1280, y: 0, width: 1280, height: 1024)]
        let result = PanelPlacement.frame(size: NSSize(width: 390, height: 350),
            anchor: NSRect(x: -900, y: 300, width: 100, height: 20), mouseLocation: .zero, screens: screens)
        #expect(screens[1].contains(result))
        #expect(result.minY == 330)
    }

    @Test func pillPlacementPreservesItsCompactRequestedSize() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = PanelPlacement.frame(size: NSSize(width: 298, height: 40), anchor: NSRect(x: 400, y: 300, width: 80, height: 20),
                                         mouseLocation: .zero, screens: [screen])
        #expect(frame.size == NSSize(width: 298, height: 40))
        #expect(screen.contains(frame))
    }

    @Test func nearTopFallsBelowSelectionAndClampsHorizontalEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let result = PanelPlacement.frame(size: NSSize(width: 390, height: 350),
            anchor: NSRect(x: 1420, y: 850, width: 20, height: 20), mouseLocation: .zero, screens: [screen])
        #expect(result.maxX == 1432)
        #expect(result.maxY == 840)
        #expect(screen.contains(result))
    }

    @Test func missingBoundsUsesMouseDisplayAndSmallScreensFit() {
        let screen = NSRect(x: 0, y: -200, width: 300, height: 250)
        let result = PanelPlacement.frame(size: NSSize(width: 390, height: 350), anchor: nil,
            mouseLocation: NSPoint(x: 80, y: -80), screens: [screen])
        #expect(screen.contains(result))
        #expect(result.width == 284)
        #expect(result.height == 234)
    }

    @Test func restoredPanelSizeIsClampedToTheSelectedDisplay() {
        let screen = NSRect(x: -800, y: -100, width: 800, height: 600)
        let frame = PanelPlacement.frame(size: NSSize(width: 1200, height: 900),
                                         anchor: NSRect(x: -600, y: 100, width: 20, height: 20),
                                         mouseLocation: .zero, screens: [screen])
        #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
        #expect(frame.width == 784)
        #expect(frame.height == 584)
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
