import AppKit

enum PanelPlacement {
    static func frame(size: NSSize, anchor: NSRect?, mouseLocation: NSPoint, screens: [NSRect]) -> NSRect {
        let reference = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouseLocation
        let screen = screens.first(where: { $0.contains(reference) })
            ?? screens.max(by: { intersectionArea($0, anchor) < intersectionArea($1, anchor) })
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        let available = screen.insetBy(dx: margin, dy: margin)
        let width = min(size.width, max(1, available.width))
        let height = min(size.height, max(1, available.height))
        let rect = anchor ?? NSRect(origin: mouseLocation, size: .zero)
        let preferredY = rect.maxY + 10
        let y = preferredY + height <= available.maxY ? preferredY : rect.minY - height - 10
        return NSRect(
            x: min(max(rect.midX - width / 2, available.minX), available.maxX - width),
            y: min(max(y, available.minY), available.maxY - height),
            width: width, height: height
        )
    }

    private static func intersectionArea(_ screen: NSRect, _ anchor: NSRect?) -> CGFloat {
        guard let anchor else { return 0 }
        let overlap = screen.intersection(anchor)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}

@MainActor
final class PanelCardView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    var cornerRadius: CGFloat = 14
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
