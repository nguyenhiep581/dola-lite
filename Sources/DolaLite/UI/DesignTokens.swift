import AppKit

/// Centralized design tokens and native AppKit micro-interaction controls
/// (Utility profile: clean desktop symmetry, hover/press feedback only, compact text-first density).
@MainActor
enum DesignTokens {
    enum Radius {
        static let card: CGFloat = 14
        static let pill: CGFloat = 20
        static let tray: CGFloat = 8
        static let control: CGFloat = 6
        static let pillButton: CGFloat = 15
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    enum Typography {
        static let panelTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let pillAction = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let body = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        static let bodyBold = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        static let heading1 = NSFont.systemFont(ofSize: 16.5, weight: .semibold)
        static let heading2 = NSFont.systemFont(ofSize: 15, weight: .semibold)
        static let heading3 = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        static let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let rowPrimary = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        static let rowMeta = NSFont.systemFont(ofSize: 11, weight: .regular)
        static let rowSkill = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    }

    enum Colors {
        static var cardSurface: NSColor { .controlBackgroundColor }
        static var editorSurface: NSColor { .textBackgroundColor }
        // Native macOS sidebar tint (avoid .underPageBackgroundColor, which is
        // dark #9A9A9A PDF-canvas gray in Light Mode).
        static var sidebarSurface: NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(calibratedWhite: 0.14, alpha: 1)
                    : NSColor(calibratedRed: 0.953, green: 0.957, blue: 0.965, alpha: 1)
            }
        }
        static var hoverSurface: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
        static var activeSurface: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.14) }
        static var selectedRowSurface: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.14) }
        static var selectedRowBorder: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.32) }
        // Keep native separatorColor alpha (~10% light / ~18% dark); calling
        // withAlphaComponent() replaces that alpha and creates harsh dark lines.
        static var subtleBorder: NSColor { .separatorColor }
        static var codeBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    }
}

/// Appearance-aware surface container whose layer colors update automatically on Light/Dark switches.
@MainActor
final class AdaptiveSurfaceView: NSView {
    var cornerRadius: CGFloat = DesignTokens.Radius.tray
    var borderWidth: CGFloat = 1
    var fillColor: () -> NSColor = { DesignTokens.Colors.cardSurface }
    var strokeColor: () -> NSColor = { DesignTokens.Colors.subtleBorder }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = cornerRadius > 0
            layer?.borderWidth = borderWidth
            layer?.backgroundColor = fillColor().cgColor
            layer?.borderColor = strokeColor().cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Compact borderless icon button with subtle hover and active-toggle surfaces.
@MainActor
final class HoverIconButton: NSButton {
    var isActiveState: Bool = false {
        didSet {
            contentTintColor = isActiveState ? .controlAccentColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = DesignTokens.Radius.control
            if isActiveState {
                layer?.backgroundColor = DesignTokens.Colors.activeSurface.cgColor
            } else if isHovered && isEnabled {
                layer?.backgroundColor = DesignTokens.Colors.hoverSurface.cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Floating pill action button with instant hover feedback and crisp native focus ring.
@MainActor
final class HoverPillButton: NSButton {
    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = DesignTokens.Typography.pillAction
        contentTintColor = .labelColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 16, height: max(30, base.height + 12))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = DesignTokens.Radius.pillButton
            layer?.backgroundColor = isHovered
                ? DesignTokens.Colors.hoverSurface.cgColor
                : NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
