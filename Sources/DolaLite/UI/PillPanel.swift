import AppKit

@MainActor
final class PillPanel: NSPanel {
    var onSkillTap: ((Skill, String) -> Void)?
    private var selectedText = ""
    private var skills: [Skill] = [.translate, .summarize, .explain]

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 298, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let card = PanelCardView()
        card.cornerRadius = DesignTokens.Radius.pill
        contentView = card
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Spacing.xs
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        for (index, skill) in skills.enumerated() {
            let button = HoverPillButton(frame: .zero)
            button.title = skill.displayName
            button.target = self
            button.action = #selector(tapped(_:))
            button.tag = index
            button.image = NSImage(systemSymbolName: ["character.bubble", "text.alignleft", "lightbulb"][index], accessibilityDescription: skill.displayName)
            button.toolTip = skill.displayName
            button.setAccessibilityLabel(skill.displayName)
            stack.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(text: String, near rect: NSRect?) {
        selectedText = text
        setFrame(PanelPlacement.pillFrame(size: NSSize(width: 298, height: 40), anchor: rect,
                                          mouseLocation: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }

    @objc private func tapped(_ sender: NSButton) {
        guard skills.indices.contains(sender.tag) else { return }
        onSkillTap?(skills[sender.tag], selectedText)
    }
}
