import AppKit

@MainActor
final class HistoryWindowController: NSWindowController {
    private let store: HistoryStore
    private let titleLabel = NSTextField(labelWithString: "Lịch sử")
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let listScroll = NSScrollView()
    private let listStack = FlippedHistoryStackView()
    private let detailTitle = NSTextField(labelWithString: "Chọn một mục để xem kết quả")
    private let detailMetaCard = AdaptiveSurfaceView(frame: .zero)
    private let detailMetaInfo = NSTextField(labelWithString: "")
    private let detailMetaSource = NSTextField(wrappingLabelWithString: "")
    private let detailText = NSTextView()
    private let clearButton = NSButton(title: "Xóa tất cả", target: nil, action: nil)
    private let copyButton = NSButton(title: "Sao chép", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Xóa", target: nil, action: nil)
    private var selectedEntry: HistoryEntry?

    init(store: HistoryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lịch sử — Dola Lite"
        window.minSize = NSSize(width: 580, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let sidebar = AdaptiveSurfaceView(frame: .zero)
        sidebar.cornerRadius = 0
        sidebar.borderWidth = 0
        sidebar.fillColor = { DesignTokens.Colors.sidebarSurface }
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        countLabel.font = DesignTokens.Typography.caption
        countLabel.textColor = .secondaryLabelColor
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearHistory)

        let sidebarSpacer = NSView()
        let sidebarHeader = NSStackView(views: [titleLabel, countLabel, sidebarSpacer, clearButton])
        sidebarHeader.orientation = .horizontal
        sidebarHeader.alignment = .centerY
        sidebarHeader.spacing = 6
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarHeader)

        let sidebarHeaderDivider = HistoryDividerView(axis: .horizontal)
        sidebarHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarHeaderDivider)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 10, right: 6)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listScroll.documentView = listStack
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.scrollerStyle = .overlay
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(listScroll)

        NSLayoutConstraint.activate([
            sidebarHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarHeader.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            sidebarHeader.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            sidebarHeaderDivider.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor, constant: 10),
            sidebarHeaderDivider.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarHeaderDivider.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarHeaderDivider.heightAnchor.constraint(equalToConstant: 1),
            listScroll.topAnchor.constraint(equalTo: sidebarHeaderDivider.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            listStack.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor)
        ])

        let previewDivider = HistoryDividerView(axis: .vertical)
        previewDivider.translatesAutoresizingMaskIntoConstraints = false

        let detail = makeDetailView()
        detail.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebar)
        content.addSubview(previewDivider)
        content.addSubview(detail)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 264),
            previewDivider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            previewDivider.topAnchor.constraint(equalTo: content.topAnchor),
            previewDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            previewDivider.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: previewDivider.trailingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            detail.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        copyButton.isEnabled = false
        deleteButton.isEnabled = false
    }

    private func makeDetailView() -> NSView {
        let detail = NSStackView()
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10

        detailTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        detailTitle.textColor = .labelColor
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleSpacer = NSView()
        let headerRow = NSStackView(views: [detailTitle, titleSpacer, copyButton, deleteButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6
        detail.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true

        statusLabel.font = DesignTokens.Typography.caption
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.isHidden = true
        detail.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true

        detailMetaCard.cornerRadius = DesignTokens.Radius.tray
        detailMetaCard.borderWidth = 1
        detailMetaCard.fillColor = { DesignTokens.Colors.cardSurface }
        detailMetaCard.isHidden = true

        detailMetaInfo.font = DesignTokens.Typography.caption
        detailMetaInfo.textColor = .secondaryLabelColor
        detailMetaInfo.lineBreakMode = .byTruncatingTail

        detailMetaSource.font = .systemFont(ofSize: 12, weight: .regular)
        detailMetaSource.textColor = .labelColor
        detailMetaSource.maximumNumberOfLines = 2
        detailMetaSource.lineBreakMode = .byTruncatingTail

        let metaStack = NSStackView(views: [detailMetaInfo, detailMetaSource])
        metaStack.orientation = .vertical
        metaStack.alignment = .leading
        metaStack.spacing = 3
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        detailMetaCard.addSubview(metaStack)
        NSLayoutConstraint.activate([
            metaStack.leadingAnchor.constraint(equalTo: detailMetaCard.leadingAnchor, constant: 10),
            metaStack.trailingAnchor.constraint(equalTo: detailMetaCard.trailingAnchor, constant: -10),
            metaStack.topAnchor.constraint(equalTo: detailMetaCard.topAnchor, constant: 8),
            metaStack.bottomAnchor.constraint(equalTo: detailMetaCard.bottomAnchor, constant: -8),
            detailMetaInfo.widthAnchor.constraint(equalTo: metaStack.widthAnchor),
            detailMetaSource.widthAnchor.constraint(equalTo: metaStack.widthAnchor)
        ])
        detail.addArrangedSubview(detailMetaCard)
        detailMetaCard.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true

        let editorCard = AdaptiveSurfaceView(frame: .zero)
        editorCard.cornerRadius = DesignTokens.Radius.tray
        editorCard.borderWidth = 1
        editorCard.fillColor = { DesignTokens.Colors.editorSurface }

        detailText.isEditable = false
        detailText.isSelectable = true
        detailText.drawsBackground = false
        detailText.isRichText = true
        detailText.isVerticallyResizable = true
        detailText.isHorizontallyResizable = false
        detailText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailText.autoresizingMask = [.width]
        detailText.textContainerInset = NSSize(width: 10, height: 10)
        detailText.textContainer?.widthTracksTextView = true

        let textScroll = NSScrollView()
        textScroll.documentView = detailText
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = false
        textScroll.scrollerStyle = .overlay
        textScroll.drawsBackground = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        editorCard.addSubview(textScroll)
        NSLayoutConstraint.activate([
            textScroll.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 2),
            textScroll.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: -2),
            textScroll.topAnchor.constraint(equalTo: editorCard.topAnchor, constant: 2),
            textScroll.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor, constant: -2)
        ])
        detail.addArrangedSubview(editorCard)
        editorCard.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        editorCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        editorCard.setContentHuggingPriority(.defaultLow, for: .vertical)

        return detail
    }

    private func reload() {
        selectedEntry = nil
        countLabel.stringValue = store.entries.isEmpty ? "" : "(\(store.entries.count))"
        clearButton.isEnabled = !store.entries.isEmpty
        if store.hasReadError {
            setStatus("Không đọc được lịch sử cũ. Lưu mục mới sẽ thay thế tệp lịch sử bị lỗi.", color: .systemOrange)
        } else {
            setStatus("", color: .secondaryLabelColor)
        }

        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !store.entries.isEmpty else {
            detailTitle.stringValue = "Chưa có lịch sử"
            detailMetaCard.isHidden = true
            detailText.textStorage?.setAttributedString(NSAttributedString(string: ""))
            copyButton.isEnabled = false
            deleteButton.isEnabled = false

            let empty = NSTextField(wrappingLabelWithString: "Các bản dịch, tóm tắt và giải thích hoàn tất sẽ xuất hiện ở đây.")
            empty.font = DesignTokens.Typography.caption
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -16).isActive = true
            return
        }

        for (index, entry) in store.entries.enumerated() {
            let formattedDate = Self.dateFormatter.string(from: entry.createdAt)
            let row = HistoryRowButton(entry: entry, formattedDate: formattedDate,
                                       target: self, action: #selector(selectEntry(_:)))
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -12).isActive = true
            if index < store.entries.count - 1 {
                let divider = HistoryDividerView(axis: .horizontal)
                listStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -24).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }

        if let first = store.entries.first {
            display(entry: first)
        }
    }

    private func display(entry: HistoryEntry) {
        selectedEntry = entry
        let idString = entry.id.uuidString
        for case let row as HistoryRowButton in listStack.arrangedSubviews {
            row.isSelectedRow = (row.identifier?.rawValue == idString)
        }
        detailTitle.stringValue = entry.skill.displayName
        detailMetaInfo.stringValue = "Lưu lúc \(Self.dateFormatter.string(from: entry.createdAt))  —  \(entry.model)"
        detailMetaSource.stringValue = "Gốc: \(entry.sourcePreview)"
        detailMetaCard.isHidden = false
        detailText.textStorage?.setAttributedString(MarkdownLite.attributed(entry.resultText))
        detailText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        copyButton.isEnabled = true
        deleteButton.isEnabled = true
    }

    private func setStatus(_ message: String, color: NSColor) {
        statusLabel.stringValue = message
        statusLabel.textColor = color
        statusLabel.isHidden = message.isEmpty
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    @objc private func selectEntry(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString),
              let entry = store.entries.first(where: { $0.id == id }) else { return }
        setStatus("", color: .secondaryLabelColor)
        display(entry: entry)
    }

    @objc private func copySelected() {
        guard let selectedEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedEntry.resultText, forType: .string)
        setStatus("Đã sao chép kết quả vào clipboard.", color: .systemGreen)
    }

    @objc private func deleteSelected() {
        guard let selectedEntry else { return }
        do {
            try store.remove(id: selectedEntry.id)
            reload()
            setStatus("Đã xóa mục khỏi lịch sử.", color: .secondaryLabelColor)
        } catch {
            setStatus(error.localizedDescription, color: .systemRed)
        }
    }

    @objc private func clearHistory() {
        guard !store.entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Xóa toàn bộ lịch sử?"
        alert.informativeText = "Thao tác này không thể hoàn tác."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Xóa tất cả")
        alert.addButton(withTitle: "Hủy")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.removeAll()
            reload()
            setStatus("Đã xóa toàn bộ lịch sử.", color: .secondaryLabelColor)
        } catch {
            setStatus(error.localizedDescription, color: .systemRed)
        }
    }
}
