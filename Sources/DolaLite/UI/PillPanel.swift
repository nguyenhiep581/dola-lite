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
        card.cornerRadius = 20
        contentView = card
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7)
        stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        for (index, skill) in skills.enumerated() {
            let button = NSButton(title: skill.displayName, target: self, action: #selector(tapped(_:)))
            button.tag = index
            button.image = NSImage(systemSymbolName: ["character.bubble", "text.alignleft", "lightbulb"][index], accessibilityDescription: skill.displayName)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = .labelColor
            button.toolTip = skill.displayName
            button.setAccessibilityLabel(skill.displayName)
            stack.addArrangedSubview(button)
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
        setFrame(PanelPlacement.frame(size: NSSize(width: 298, height: 40), anchor: rect,
                                      mouseLocation: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }

    @objc private func tapped(_ sender: NSButton) {
        guard skills.indices.contains(sender.tag) else { return }
        onSkillTap?(skills[sender.tag], selectedText)
    }
}
