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
}
