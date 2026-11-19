import AppKit

enum PanelPlacement {
    static func frame(size: NSSize, anchor: NSRect?, mouseLocation: NSPoint, screens: [NSRect],
                      minimumSize: NSSize = .zero) -> NSRect {
        let reference = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouseLocation
        let screen = screens.first(where: { $0.contains(reference) })
            ?? screens.max(by: { intersectionArea($0, anchor ?? NSRect(origin: reference, size: .zero))
                < intersectionArea($1, anchor ?? NSRect(origin: reference, size: .zero)) })
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        let available = screen.insetBy(dx: margin, dy: margin)
        let widthLimit = max(1, available.width)
        let heightLimit = max(1, available.height)
        let requestedWidth = size.width.isFinite && size.width > 0 ? size.width : 390
        let requestedHeight = size.height.isFinite && size.height > 0 ? size.height : 350
        let width = min(max(requestedWidth, min(minimumSize.width, widthLimit)), widthLimit)
        let height = min(max(requestedHeight, min(minimumSize.height, heightLimit)), heightLimit)
        let rect = anchor ?? NSRect(origin: mouseLocation, size: .zero)
        let preferredY = rect.maxY + 10
        let y = preferredY + height <= available.maxY ? preferredY : rect.minY - height - 10
        return NSRect(
            x: min(max(rect.midX - width / 2, available.minX), available.maxX - width),
            y: min(max(y, available.minY), available.maxY - height),
            width: width, height: height
        )
    }

    static func clampedFrame(_ frame: NSRect, screens: [NSRect],
                             minimumSize: NSSize = NSSize(width: 320, height: 240),
                             margin: CGFloat = 8) -> NSRect {
        let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let reference = NSPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first(where: { $0.contains(reference) })
            ?? screens.max(by: { intersectionArea($0, frame) < intersectionArea($1, frame) })
            ?? fallback
        let available = screen.insetBy(dx: margin, dy: margin)
        let widthLimit = max(1, available.width)
        let heightLimit = max(1, available.height)
        let width = min(max(frame.width, min(minimumSize.width, widthLimit)), widthLimit)
        let height = min(max(frame.height, min(minimumSize.height, heightLimit)), heightLimit)
        let x = min(max(frame.minX, available.minX), available.maxX - width)
        let y = min(max(frame.minY, available.minY), available.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func resizedFrame(_ initialFrame: NSRect, delta: NSPoint, screens: [NSRect],
                             minimumSize: NSSize = NSSize(width: 320, height: 240),
                             margin: CGFloat = 8) -> NSRect {
        let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let reference = NSPoint(x: initialFrame.midX, y: initialFrame.midY)
        let screen = screens.first(where: { $0.contains(reference) })
            ?? screens.max(by: { intersectionArea($0, initialFrame) < intersectionArea($1, initialFrame) })
            ?? fallback
        let available = screen.insetBy(dx: margin, dy: margin)
        let widthLimit = max(1, available.width)
        let heightLimit = max(1, available.height)
        let minWidth = min(minimumSize.width, widthLimit)
        let minHeight = min(minimumSize.height, heightLimit)

        // Anchor the top-left corner (minX, maxY) on the panel's current screen
        // so dragging past right/bottom edges or monitor seams cannot slide the
        // anchored edges or teleport the panel onto another display.
        let anchoredMinX = min(max(initialFrame.minX, available.minX), available.maxX - minWidth)
        let anchoredMaxY = min(max(initialFrame.maxY, available.minY + minHeight), available.maxY)
        let maxWidth = max(minWidth, available.maxX - anchoredMinX)
        let maxHeight = max(minHeight, anchoredMaxY - available.minY)

        // The handle is at the bottom-right; a positive screen-space y delta
        // means the pointer moves up, shrinking height while keeping maxY fixed.
        let width = min(max(minWidth, initialFrame.width + delta.x), maxWidth)
        let height = min(max(minHeight, initialFrame.height - delta.y), maxHeight)
        return NSRect(x: anchoredMinX, y: anchoredMaxY - height, width: width, height: height)
    }

    static func historyTrayHeight(originalHeight: CGFloat, expandedHeight: CGFloat,
                                  minimum: CGFloat = 96, maximum: CGFloat = 170,
                                  contentGap: CGFloat = 16) -> CGFloat {
        min(maximum, max(minimum, expandedHeight - originalHeight - contentGap))
    }

    private static func intersectionArea(_ screen: NSRect, _ rect: NSRect) -> CGFloat {
        let overlap = screen.intersection(rect)
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
