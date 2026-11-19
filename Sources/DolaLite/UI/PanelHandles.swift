import AppKit

@MainActor
final class PanelDragHandle: NSView {
    private var dragOrigin: NSPoint?
    private var initialFrame: NSRect?

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Kéo để di chuyển cửa sổ"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Kéo để di chuyển cửa sổ")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        initialFrame = window?.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let initialFrame, let window else { return }
        let pointer = NSEvent.mouseLocation
        var proposed = initialFrame
        proposed.origin.x += pointer.x - dragOrigin.x
        proposed.origin.y += pointer.y - dragOrigin.y
        window.setFrame(PanelPlacement.clampedFrame(proposed, screens: NSScreen.screens.map(\.visibleFrame),
                                                    minimumSize: window.minSize), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        initialFrame = nil
    }
}

@MainActor
final class PanelResizeHandle: NSView {
    var onResize: ((NSRect, NSPoint) -> Void)?
    var onResizeEnd: (() -> Void)?
    private var initialFrame: NSRect?
    private var dragOrigin: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Kéo để thay đổi kích thước"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Kéo để thay đổi kích thước")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.tertiaryLabelColor.setStroke()
        for inset in [CGFloat(5), 9, 13] {
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + inset))
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        initialFrame = window?.frame
        dragOrigin = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialFrame, let dragOrigin else { return }
        didDrag = true
        let pointer = NSEvent.mouseLocation
        onResize?(initialFrame, NSPoint(x: pointer.x - dragOrigin.x, y: pointer.y - dragOrigin.y))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldNotifyEnd = didDrag
        initialFrame = nil
        dragOrigin = nil
        didDrag = false
        if shouldNotifyEnd { onResizeEnd?() }
    }
}
