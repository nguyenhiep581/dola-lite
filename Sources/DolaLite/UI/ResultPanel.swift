import AppKit

@MainActor
final class ResultPanel: NSPanel {
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Thử lại", target: nil, action: nil)
    private let copyButton = NSButton()
    private(set) var fullText = ""
    private var pendingRender: Task<Void, Never>?
    private var isStreaming = false
    // First-token latency varies widely with the relay (2–20 s); a live
    // seconds counter keeps the wait legible instead of a frozen status.
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var waitingPhrase = "Đang chuẩn bị…"

    private func startElapsedCounter() {
        elapsedTimer?.invalidate()
        startedAt = Date()
        statusLabel.stringValue = waitingPhrase
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStreaming, self.fullText.isEmpty, let startedAt = self.startedAt else { return }
                self.statusLabel.stringValue = "\(self.waitingPhrase) \(Int(Date().timeIntervalSince(startedAt)))s"
            }
        }
    }

    private func stopElapsedCounter() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 390, height: 350),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let card = PanelCardView()
        contentView = card
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)
        configureIcon(copyButton, symbol: "doc.on.doc", title: "Sao chép kết quả", action: #selector(copyAll))
        let closeButton = NSButton()
        configureIcon(closeButton, symbol: "xmark", title: "Đóng", action: #selector(closeResult))
        for button in [copyButton, closeButton] { button.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(button) }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(divider)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 365, height: 1)
        // Geometry is pinned explicitly in syncContainerWidth(); autoresizing
        // on a document view inside NSClipView doubles the width (733=2×365+3).
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 3, height: 4)
        // Wrap width is driven explicitly (see syncContainerWidth): the
        // container-in-scrollview tracking feedback loop inflates the width
        // to the longest line and enables horizontal scrolling.
        textView.textContainer?.widthTracksTextView = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        // Overlay scrollers never change the clip width, so the pinned wrap
        // width stays valid for the panel's lifetime.
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scrollView)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(spinner)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .inline
        retryButton.font = .systemFont(ofSize: 11, weight: .medium)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(retryButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            divider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            retryButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            retryButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { closeResult() }

    func show(skill: Skill, near rect: NSRect?) {
        pendingRender?.cancel(); pendingRender = nil
        fullText = ""
        isStreaming = true
        titleLabel.stringValue = skill.displayName
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        let verb = skill.displayName.prefix(1).lowercased() + skill.displayName.dropFirst()
        waitingPhrase = "Đang \(verb)…"
        statusLabel.textColor = .secondaryLabelColor
        copyButton.isEnabled = false
        retryButton.isHidden = true
        spinner.startAnimation(nil)
        startElapsedCounter()
        setFrame(PanelPlacement.frame(size: NSSize(width: 390, height: 350), anchor: rect,
                                      mouseLocation: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
        syncContainerWidth()
        orderFrontRegardless()
    }

    /// Pin the wrap width to the visible scroll width. The panel is fixed-size,
    /// so this runs once per show — no tracking, no feedback loop.
    private func syncContainerWidth() {
        scrollView.layoutSubtreeIfNeeded()
        let clipWidth = scrollView.contentView.bounds.width
        let width = clipWidth - textView.textContainerInset.width * 2
        guard width > 50 else { return }
        textView.frame.size.width = clipWidth
        textView.textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        fullText += chunk
        spinner.stopAnimation(nil)
        stopElapsedCounter()
        statusLabel.stringValue = "Đang trả lời…"
        copyButton.isEnabled = true
        guard pendingRender == nil else { return }
        pendingRender = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            guard let self else { return }
            self.pendingRender = nil
            self.render()
        }
    }

    func finish() {
        isStreaming = false
        pendingRender?.cancel(); pendingRender = nil
        render()
        spinner.stopAnimation(nil)
        stopElapsedCounter()
        statusLabel.stringValue = "Đã hoàn tất"
        copyButton.isEnabled = !fullText.isEmpty
    }

    func fail(_ message: String) {
        isStreaming = false
        pendingRender?.cancel(); pendingRender = nil
        render()
        spinner.stopAnimation(nil)
        stopElapsedCounter()
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        retryButton.isHidden = false
        copyButton.isEnabled = !fullText.isEmpty
    }

    func dismiss() {
        pendingRender?.cancel(); pendingRender = nil
        isStreaming = false
        spinner.stopAnimation(nil)
        stopElapsedCounter()
        orderOut(nil)
    }

    private func render() {
        let visible = scrollView.contentView.bounds
        let shouldScroll = textView.bounds.height <= visible.height + 4 || visible.maxY >= textView.bounds.maxY - 28
        textView.textStorage?.setAttributedString(MarkdownLite.attributed(fullText))
        if shouldScroll { textView.scrollToEndOfDocument(nil) }
    }

    private func configureIcon(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullText, forType: .string)
    }
    @objc private func closeResult() { dismiss(); onClose?() }
    @objc private func retry() { onRetry?() }
}
