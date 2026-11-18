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
}
