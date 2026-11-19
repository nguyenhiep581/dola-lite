import AppKit

@MainActor
final class ResultPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    var onPinChange: ((Bool) -> Void)?
    var onSelectHistory: (() -> Void)?
    private static let baseMinSize = NSSize(width: 320, height: 240)
    private let sizeStore: ResultPanelSizeStore
    private let historyStore: HistoryStore?
    private let titleLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Thử lại", target: nil, action: nil)
    private let copyButton = HoverIconButton(frame: .zero)
    private let pinButton = HoverIconButton(frame: .zero)
    private let historyButton = HoverIconButton(frame: .zero)
    private let dragHandle = PanelDragHandle(frame: .zero)
    private let resizeHandle = PanelResizeHandle(frame: .zero)
    private let historyContainer = AdaptiveSurfaceView(frame: .zero)
    private let historyTitle = NSTextField(labelWithString: "Lịch sử gần đây")
    private let historyCountLabel = NSTextField(labelWithString: "")
    private let historyScroll = NSScrollView()
    private let historyStack = FlippedHistoryStackView()
    private var historyHeightConstraint: NSLayoutConstraint!
    private var frameBeforeHistory: NSRect?
    private var historyExtraHeight: CGFloat = 0
    private var selectedHistoryID: UUID?
    private var isProgrammaticFrameChange = false
    private(set) var isPinned = false
    private(set) var isHistoryVisible = false
    private(set) var fullText = ""
    private var pendingRender: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?
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

    init(historyStore: HistoryStore? = nil, sizeStore: ResultPanelSizeStore? = nil) {
        self.sizeStore = sizeStore ?? ResultPanelSizeStore()
        self.historyStore = historyStore
        super.init(contentRect: NSRect(x: 0, y: 0, width: 390, height: 350),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        delegate = self
        minSize = Self.baseMinSize
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let card = PanelCardView()
        contentView = card
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(dragHandle)
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(resizeHandle)
        resizeHandle.onResize = { [weak self] initialFrame, delta in
            self?.resize(from: initialFrame, delta: delta)
        }
        resizeHandle.onResizeEnd = { [weak self] in
            self?.persistCurrentSizeIfEligible()
        }
        titleLabel.font = DesignTokens.Typography.panelTitle
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)
        configureIcon(copyButton, symbol: "doc.on.doc", title: "Sao chép kết quả", action: #selector(copyAll))
        configureIcon(pinButton, symbol: "pin", title: "Giữ cửa sổ mở", action: #selector(togglePin))
        configureIcon(historyButton, symbol: "clock.arrow.circlepath", title: "Lịch sử", action: #selector(openHistory))
        let closeButton = HoverIconButton(frame: .zero)
        configureIcon(closeButton, symbol: "xmark", title: "Đóng", action: #selector(closeResult))
        for button in [historyButton, pinButton, copyButton, closeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(button)
        }
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
        historyContainer.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.isHidden = true
        historyContainer.cornerRadius = DesignTokens.Radius.tray
        historyContainer.borderWidth = 1
        historyContainer.fillColor = { DesignTokens.Colors.cardSurface }
        card.addSubview(historyContainer)
        historyTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        historyTitle.textColor = .secondaryLabelColor
        historyTitle.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.addSubview(historyTitle)
        historyCountLabel.font = DesignTokens.Typography.caption
        historyCountLabel.textColor = .tertiaryLabelColor
        historyCountLabel.alignment = .right
        historyCountLabel.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.addSubview(historyCountLabel)
        let historyHeaderDivider = HistoryDividerView(axis: .horizontal)
        historyHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.addSubview(historyHeaderDivider)
        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 2
        historyStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 6, right: 4)
        historyStack.translatesAutoresizingMaskIntoConstraints = false
        historyScroll.documentView = historyStack
        historyScroll.hasVerticalScroller = true
        historyScroll.hasHorizontalScroller = false
        historyScroll.scrollerStyle = .overlay
        historyScroll.drawsBackground = false
        historyScroll.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.addSubview(historyScroll)
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
            historyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            historyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: historyButton.leadingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),
            dragHandle.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            dragHandle.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -6),
            dragHandle.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            dragHandle.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            divider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: historyContainer.topAnchor, constant: -8),
            historyContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            historyContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            historyContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            historyTitle.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor, constant: 10),
            historyTitle.topAnchor.constraint(equalTo: historyContainer.topAnchor, constant: 7),
            historyCountLabel.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor, constant: -10),
            historyCountLabel.centerYAnchor.constraint(equalTo: historyTitle.centerYAnchor),
            historyHeaderDivider.topAnchor.constraint(equalTo: historyTitle.bottomAnchor, constant: 6),
            historyHeaderDivider.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor),
            historyHeaderDivider.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor),
            historyHeaderDivider.heightAnchor.constraint(equalToConstant: 1),
            historyScroll.topAnchor.constraint(equalTo: historyHeaderDivider.bottomAnchor, constant: 2),
            historyScroll.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor, constant: 2),
            historyScroll.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor, constant: -2),
            historyStack.leadingAnchor.constraint(equalTo: historyScroll.contentView.leadingAnchor),
            historyStack.trailingAnchor.constraint(equalTo: historyScroll.contentView.trailingAnchor),
            historyStack.topAnchor.constraint(equalTo: historyScroll.contentView.topAnchor),
            historyStack.widthAnchor.constraint(equalTo: historyScroll.contentView.widthAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            retryButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),
            retryButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            resizeHandle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -5),
            resizeHandle.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -5),
            resizeHandle.widthAnchor.constraint(equalToConstant: 20),
            resizeHandle.heightAnchor.constraint(equalToConstant: 20),
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
        historyHeightConstraint = historyContainer.heightAnchor.constraint(equalToConstant: 0)
        historyHeightConstraint.isActive = true
        // Lower bottom priority so collapsing historyContainer to height 0 never
        // conflicts with the header/divider vertical constraints.
        let historyScrollBottom = historyScroll.bottomAnchor.constraint(equalTo: historyContainer.bottomAnchor, constant: -2)
        historyScrollBottom.priority = .defaultHigh
        historyScrollBottom.isActive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { closeResult() }

    func windowDidResize(_ notification: Notification) {
        guard frame.width >= minSize.width, frame.height >= minSize.height else { return }
        syncContainerWidth()
        if !isProgrammaticFrameChange, isHistoryVisible, frameBeforeHistory != nil {
            let collapsedHeight = max(Self.baseMinSize.height, frame.height - historyExtraHeight)
            frameBeforeHistory = NSRect(x: frame.minX,
                                        y: frame.maxY - collapsedHeight,
                                        width: frame.width,
                                        height: collapsedHeight)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistCurrentSizeIfEligible()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticFrameChange else { return }
        let clamped = PanelPlacement.clampedFrame(frame, screens: NSScreen.screens.map(\.visibleFrame), minimumSize: minSize)
        if clamped != frame {
            isProgrammaticFrameChange = true
            setFrame(clamped, display: true)
            isProgrammaticFrameChange = false
        }
        if isHistoryVisible, let previous = frameBeforeHistory {
            frameBeforeHistory = NSRect(x: frame.minX,
                                        y: frame.maxY - previous.height,
                                        width: previous.width,
                                        height: previous.height)
        }
    }

    private func persistCurrentSizeIfEligible() {
        guard !isProgrammaticFrameChange,
              frame.width >= minSize.width, frame.height >= minSize.height else { return }
        if isHistoryVisible {
            if let collapsed = frameBeforeHistory { sizeStore.save(collapsed.size) }
        } else {
            sizeStore.save(frame.size)
        }
    }

    private func resize(from initialFrame: NSRect, delta: NSPoint) {
        let resized = PanelPlacement.resizedFrame(initialFrame, delta: delta,
                                                  screens: NSScreen.screens.map(\.visibleFrame),
                                                  minimumSize: minSize)
        setFrame(resized, display: true)
    }

    func show(skill: Skill, near rect: NSRect?) {
        hideHistory(restoreFrame: true)
        resetCopyFeedback()
        pendingRender?.cancel(); pendingRender = nil
        selectedHistoryID = nil
        fullText = ""
        isStreaming = true
        setPinned(false)
        titleLabel.stringValue = skill.displayName
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        let verb = skill.displayName.prefix(1).lowercased() + skill.displayName.dropFirst()
        waitingPhrase = "Đang \(verb)…"
        statusLabel.textColor = .secondaryLabelColor
        copyButton.isEnabled = false
        retryButton.isHidden = true
        spinner.startAnimation(nil)
        startElapsedCounter()
        let preferredSize = sizeStore.load(default: NSSize(width: 390, height: 350))
        isProgrammaticFrameChange = true
        setFrame(PanelPlacement.frame(size: preferredSize, anchor: rect,
                                      mouseLocation: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.visibleFrame),
                                      minimumSize: minSize), display: true)
        isProgrammaticFrameChange = false
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
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
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
        hideHistory(restoreFrame: false)
        resetCopyFeedback()
        selectedHistoryID = nil
        if isPinned { setPinned(false, notify: false) }
        pendingRender?.cancel(); pendingRender = nil
        isStreaming = false
        spinner.stopAnimation(nil)
        stopElapsedCounter()
        orderOut(nil)
    }

    func toggleHistory() {
        guard historyStore != nil else { return }
        if isHistoryVisible {
            hideHistory(restoreFrame: true)
        } else {
            showHistory()
        }
        historyButton.isActiveState = isHistoryVisible
        historyButton.toolTip = isHistoryVisible ? "Ẩn lịch sử" : "Lịch sử"
        historyButton.setAccessibilityLabel(historyButton.toolTip ?? "Lịch sử")
    }

    private func showHistory() {
        guard let historyStore else { return }
        frameBeforeHistory = frame
        reloadHistory(historyStore.entries)
        isHistoryVisible = true
        historyContainer.isHidden = false
        let original = frame
        let desired = NSRect(x: original.minX, y: original.maxY - (original.height + 180),
                             width: original.width, height: original.height + 180)
        let expanded = PanelPlacement.clampedFrame(desired, screens: NSScreen.screens.map(\.visibleFrame), minimumSize: Self.baseMinSize)
        // If the panel already fills the display, still reserve a compact
        // tray by allowing the result scroll view to shrink. Never report an
        // open history tray with zero height.
        let extra = PanelPlacement.historyTrayHeight(originalHeight: original.height,
                                                     expandedHeight: expanded.height)
        historyExtraHeight = max(0, expanded.height - original.height)
        historyHeightConstraint.constant = extra
        // Raise minimum height while the tray is open so resizing upward
        // cannot crush the result scroll view or violate Auto Layout.
        minSize = NSSize(width: Self.baseMinSize.width,
                         height: min(expanded.height, Self.baseMinSize.height + extra))
        isProgrammaticFrameChange = true
        setFrame(expanded, display: true)
        isProgrammaticFrameChange = false
        contentView?.layoutSubtreeIfNeeded()
    }

    private func hideHistory(restoreFrame: Bool) {
        guard isHistoryVisible || frameBeforeHistory != nil else { return }
        isHistoryVisible = false
        historyExtraHeight = 0
        minSize = Self.baseMinSize
        historyButton.isActiveState = false
        historyButton.toolTip = "Lịch sử"
        historyButton.setAccessibilityLabel("Lịch sử")
        historyContainer.isHidden = true
        historyHeightConstraint?.constant = 0
        if restoreFrame, let original = frameBeforeHistory {
            let clamped = PanelPlacement.clampedFrame(original, screens: NSScreen.screens.map(\.visibleFrame), minimumSize: Self.baseMinSize)
            isProgrammaticFrameChange = true
            setFrame(clamped, display: true)
            isProgrammaticFrameChange = false
        }
        frameBeforeHistory = nil
    }

    private func reloadHistory(_ entries: [HistoryEntry]) {
        historyCountLabel.stringValue = entries.isEmpty ? "" : "\(entries.count) mục"
        for view in historyStack.arrangedSubviews {
            historyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !entries.isEmpty else {
            let empty = NSTextField(labelWithString: "Chưa có lịch sử hoàn tất")
            empty.font = DesignTokens.Typography.caption
            empty.textColor = .secondaryLabelColor
            historyStack.addArrangedSubview(empty)
            return
        }
        for (index, entry) in entries.enumerated() {
            let formattedDate = Self.historyDateFormatter.string(from: entry.createdAt)
            let row = HistoryRowButton(entry: entry, formattedDate: formattedDate,
                                       target: self, action: #selector(selectHistory(_:)))
            row.isSelectedRow = (entry.id == selectedHistoryID)
            historyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: historyStack.widthAnchor, constant: -8).isActive = true
            if index < entries.count - 1 {
                let divider = HistoryDividerView(axis: .horizontal)
                historyStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: historyStack.widthAnchor, constant: -20).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    func showHistorySaveWarning(_ message: String) {
        statusLabel.textColor = .systemOrange
        statusLabel.stringValue = message
    }

    private func setPinned(_ pinned: Bool, notify: Bool = true) {
        isPinned = pinned
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                  accessibilityDescription: pinned ? "Bỏ ghim kết quả" : "Giữ cửa sổ mở")
        pinButton.toolTip = pinned ? "Bỏ ghim kết quả" : "Giữ cửa sổ mở"
        pinButton.setAccessibilityLabel(pinButton.toolTip ?? "Ghim kết quả")
        pinButton.isActiveState = pinned
        if notify { onPinChange?(pinned) }
    }

    private func resetCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Sao chép kết quả")
        copyButton.toolTip = "Sao chép kết quả"
        copyButton.setAccessibilityLabel("Sao chép kết quả")
        copyButton.isActiveState = false
    }

    private func render() {
        let visible = scrollView.contentView.bounds
        let shouldScroll = textView.bounds.height <= visible.height + 4 || visible.maxY >= textView.bounds.maxY - 28
        textView.textStorage?.setAttributedString(MarkdownLite.attributed(fullText))
        if shouldScroll { textView.scrollToEndOfDocument(nil) }
    }

    private func configureIcon(_ button: HoverIconButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.target = self
        button.action = action
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullText, forType: .string)
        copyFeedbackTask?.cancel()
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Đã sao chép")
        copyButton.toolTip = "Đã sao chép"
        copyButton.setAccessibilityLabel("Đã sao chép")
        copyButton.isActiveState = true
        copyFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_400_000_000) } catch { return }
            self?.resetCopyFeedback()
        }
    }
    @objc private func togglePin() { setPinned(!isPinned) }
    @objc private func openHistory() { toggleHistory() }
    @objc private func selectHistory(_ sender: NSButton) {
        guard let historyStore,
              let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString),
              let entry = historyStore.entries.first(where: { $0.id == id }) else { return }
        onSelectHistory?()
        resetCopyFeedback()
        pendingRender?.cancel(); pendingRender = nil
        isStreaming = false
        spinner.stopAnimation(nil)
        stopElapsedCounter()
        selectedHistoryID = entry.id
        for case let row as HistoryRowButton in historyStack.arrangedSubviews {
            row.isSelectedRow = (row.identifier?.rawValue == idString)
        }
        titleLabel.stringValue = entry.skill.displayName
        fullText = entry.resultText
        textView.textStorage?.setAttributedString(MarkdownLite.attributed(fullText))
        textView.scrollToBeginningOfDocument(nil)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Đã lưu lúc \(Self.historyDateFormatter.string(from: entry.createdAt)) (\(entry.model))"
        retryButton.isHidden = true
        copyButton.isEnabled = !fullText.isEmpty
        syncContainerWidth()
    }
    @objc private func closeResult() { dismiss(); onClose?() }
    @objc private func retry() { onRetry?() }
}
