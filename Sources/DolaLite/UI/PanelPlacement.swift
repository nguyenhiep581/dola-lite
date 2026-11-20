import AppKit

enum PanelPlacement {
    /// Places the quick-action pill cleanly BELOW the selected text by default
    /// so browser inline selection toolbars (such as Jira's "Ask Rovo") above
    /// the selection do not overlap Dola Lite. Falls back above when near the
    /// bottom work-area edge, filters off-screen anchors, and collapses huge
    /// selections toward the nearby pointer.
    static func pillFrame(size: NSSize, anchor: NSRect?, mouseLocation: NSPoint, screens: [NSRect],
                          minimumSize: NSSize = .zero) -> NSRect {
        let validAnchor = onScreenAnchor(anchor, screens: screens)
        let placedAnchor: NSRect?
        if let u = validAnchor, u.width > 600 || u.height > 220 {
            let clampedX = min(max(mouseLocation.x, u.minX), u.maxX)
            let clampedY = min(max(mouseLocation.y, u.minY), u.maxY)
            let dist = hypot(mouseLocation.x - clampedX, mouseLocation.y - clampedY)
            placedAnchor = dist <= 140
                ? NSRect(x: mouseLocation.x, y: mouseLocation.y - 12, width: 1, height: 24)
                : u
        } else {
            placedAnchor = validAnchor
        }
        let reference = placedAnchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouseLocation
        let available = availableBounds(reference: reference, anchor: placedAnchor, screens: screens)
        let fitted = fittedSize(size, available: available, minimumSize: minimumSize)
        let rect = placedAnchor ?? NSRect(origin: mouseLocation, size: .zero)
        let gap: CGFloat = 12
        let belowY = rect.minY - fitted.height - gap
        let aboveY = rect.maxY + gap
        let y = belowY >= available.minY ? belowY : aboveY
        return NSRect(
            x: min(max(rect.midX - fitted.width / 2, available.minX), available.maxX - fitted.width),
            y: min(max(y, available.minY), available.maxY - fitted.height),
            width: fitted.width, height: fitted.height
        )
    }

    /// Opens the result panel in-place centered on the clicked pill with its
    /// top edge aligned to `anchor.maxY`, keeping highlighted text above free.
    static func resultFrame(size: NSSize, anchor: NSRect?, mouseLocation: NSPoint, screens: [NSRect],
                            minimumSize: NSSize = .zero) -> NSRect {
        let validAnchor = onScreenAnchor(anchor, screens: screens)
        let reference = validAnchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouseLocation
        let available = availableBounds(reference: reference, anchor: validAnchor, screens: screens)
        let fitted = fittedSize(size, available: available, minimumSize: minimumSize)
        let anchorMidX = validAnchor?.midX ?? mouseLocation.x
        let anchorTopY = validAnchor?.maxY ?? mouseLocation.y
        return NSRect(
            x: min(max(anchorMidX - fitted.width / 2, available.minX), available.maxX - fitted.width),
            y: min(max(anchorTopY - fitted.height, available.minY), available.maxY - fitted.height),
            width: fitted.width, height: fitted.height
        )
    }

    private static func onScreenAnchor(_ anchor: NSRect?, screens: [NSRect]) -> NSRect? {
        guard let anchor,
              !anchor.isNull, !anchor.isInfinite,
              anchor.minX.isFinite, anchor.minY.isFinite,
              anchor.width.isFinite, anchor.height.isFinite else {
            return nil
        }
        guard !screens.isEmpty else { return anchor }
        if anchor.width <= 0 || anchor.height <= 0 {
            return screens.contains(where: { $0.contains(anchor.origin) }) ? anchor : nil
        }
        return screens.contains(where: { $0.intersects(anchor) }) ? anchor : nil
    }

    private static func availableBounds(reference: NSPoint, anchor: NSRect?, screens: [NSRect],
                                        margin: CGFloat = 8) -> NSRect {
        let candidate: NSRect?
        if let containing = screens.first(where: { $0.contains(reference) }) {
            candidate = containing
        } else if let anchor,
                  let overlapping = screens.max(by: { intersectionArea($0, anchor) < intersectionArea($1, anchor) }),
                  intersectionArea(overlapping, anchor) > 0 {
            candidate = overlapping
        } else {
            candidate = screens.min(by: { distanceSquared(from: reference, to: $0) < distanceSquared(from: reference, to: $1) })
        }
        let screen = candidate ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return screen.insetBy(dx: margin, dy: margin)
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func fittedSize(_ size: NSSize, available: NSRect, minimumSize: NSSize) -> NSSize {
        let widthLimit = max(1, available.width)
        let heightLimit = max(1, available.height)
        let requestedWidth = size.width.isFinite && size.width > 0 ? size.width : 390
        let requestedHeight = size.height.isFinite && size.height > 0 ? size.height : 350
        return NSSize(
            width: min(max(requestedWidth, min(minimumSize.width, widthLimit)), widthLimit),
            height: min(max(requestedHeight, min(minimumSize.height, heightLimit)), heightLimit)
        )
    }

    static func clampedFrame(_ frame: NSRect, screens: [NSRect],
                             minimumSize: NSSize = NSSize(width: 320, height: 240),
                             margin: CGFloat = 8) -> NSRect {
        let available = availableBounds(reference: NSPoint(x: frame.midX, y: frame.midY),
                                        anchor: frame, screens: screens, margin: margin)
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
        let available = availableBounds(reference: NSPoint(x: initialFrame.midX, y: initialFrame.midY),
                                        anchor: initialFrame, screens: screens, margin: margin)
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
