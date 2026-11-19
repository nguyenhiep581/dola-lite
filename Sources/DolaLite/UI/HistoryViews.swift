import AppKit

@MainActor
final class FlippedHistoryStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class HistoryDividerView: NSView {
    enum Axis: Equatable { case horizontal, vertical }
    let axis: Axis

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        axis == .horizontal
            ? NSSize(width: NSView.noIntrinsicMetric, height: 1)
            : NSSize(width: 1, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// Variable-height, two-line history row button with clean hierarchy (primary source preview +
/// left/right skill and timestamp metadata) and Light/Dark-adaptive hover & selection states.
@MainActor
final class HistoryRowButton: NSButton {
    var isSelectedRow: Bool = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    private let previewLabel = NSTextField(labelWithString: "")
    private let skillLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    init(entry: HistoryEntry, formattedDate: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        self.title = "\(entry.skill.displayName) — \(entry.sourcePreview)"
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.image = nil
        self.wantsLayer = true
        self.translatesAutoresizingMaskIntoConstraints = false
        self.setAccessibilityLabel("\(entry.skill.displayName), \(formattedDate), \(entry.sourcePreview)")

        previewLabel.stringValue = entry.sourcePreview
        previewLabel.font = DesignTokens.Typography.rowPrimary
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        skillLabel.stringValue = entry.skill.displayName
        skillLabel.font = DesignTokens.Typography.rowSkill
        skillLabel.textColor = .secondaryLabelColor
        skillLabel.lineBreakMode = .byTruncatingTail

        dateLabel.stringValue = formattedDate
        dateLabel.font = DesignTokens.Typography.rowMeta
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let metaSpacer = NSView()
        let metaRow = NSStackView(views: [skillLabel, metaSpacer, dateLabel])
        metaRow.orientation = .horizontal
        metaRow.alignment = .firstBaseline
        metaRow.spacing = DesignTokens.Spacing.sm

        let container = NSStackView(views: [previewLabel, metaRow])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 3
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            previewLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            metaRow.widthAnchor.constraint(equalTo: container.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = DesignTokens.Radius.control
            if isSelectedRow {
                layer?.backgroundColor = DesignTokens.Colors.activeSurface.cgColor
            } else if isHovered {
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
