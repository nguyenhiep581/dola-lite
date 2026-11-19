import AppKit

@MainActor
final class HistoryWindowController: NSWindowController {
    private let store: HistoryStore
    private let titleLabel = NSTextField(labelWithString: "Lịch sử")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let listScroll = NSScrollView()
    private let listStack = FlippedHistoryStackView()
    private let detailTitle = NSTextField(labelWithString: "Chọn một mục để xem kết quả")
    private let detailMeta = NSTextField(wrappingLabelWithString: "")
    private let detailText = NSTextView()
    private let clearButton = NSButton(title: "Xóa tất cả…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Sao chép", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Xóa mục", target: nil, action: nil)
    private var selectedEntry: HistoryEntry?

    init(store: HistoryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lịch sử — Dola Lite"
        window.minSize = NSSize(width: 560, height: 360)
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
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let headerSpacer = NSView()
        let header = NSStackView(views: [titleLabel, headerSpacer, clearButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        root.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 8, right: 8)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listScroll.documentView = listStack
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.scrollerStyle = .overlay
        listScroll.drawsBackground = false

        let detail = makeDetailView()
        let previewDivider = HistoryDividerView(axis: .vertical)
        let columns = NSStackView(views: [listScroll, previewDivider, detail])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 14
        columns.distribution = .fill
        root.addArrangedSubview(columns)
        columns.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        listScroll.widthAnchor.constraint(equalToConstant: 250).isActive = true
        listScroll.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        previewDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        previewDivider.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        listStack.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor).isActive = true
        listStack.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor).isActive = true
        listStack.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor).isActive = true
        listStack.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor).isActive = true
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        detail.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true

        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        copyButton.target = self
        copyButton.action = #selector(copySelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        copyButton.isEnabled = false
        deleteButton.isEnabled = false
    }

    private func makeDetailView() -> NSView {
        let detail = NSStackView()
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 8

        detailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detail.addArrangedSubview(detailTitle)
        detailTitle.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true

        detailMeta.font = .systemFont(ofSize: 11)
        detailMeta.textColor = .secondaryLabelColor
        detailMeta.maximumNumberOfLines = 3
        detail.addArrangedSubview(detailMeta)
        detailMeta.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true

        detailText.isEditable = false
        detailText.isSelectable = true
        detailText.drawsBackground = false
        detailText.isRichText = true
        detailText.isVerticallyResizable = true
        detailText.isHorizontallyResizable = false
        detailText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailText.autoresizingMask = [.width]
        detailText.textContainerInset = NSSize(width: 8, height: 8)
        detailText.textContainer?.widthTracksTextView = true
        let textScroll = NSScrollView()
        textScroll.documentView = detailText
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = false
        textScroll.scrollerStyle = .overlay
        textScroll.drawsBackground = false
        detail.addArrangedSubview(textScroll)
        textScroll.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let actions = NSStackView(views: [copyButton, deleteButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        detail.addArrangedSubview(actions)
        return detail
    }

    private func reload() {
        selectedEntry = nil
        detailTitle.stringValue = "Chọn một mục để xem kết quả"
        detailMeta.stringValue = ""
        detailText.textStorage?.setAttributedString(NSAttributedString(string: ""))
        copyButton.isEnabled = false
        deleteButton.isEnabled = false
        statusLabel.stringValue = store.hasReadError
            ? "Không đọc được lịch sử cũ. Lưu mục mới sẽ thay thế tệp lịch sử bị lỗi."
            : ""
        statusLabel.textColor = store.hasReadError ? .systemOrange : .secondaryLabelColor

        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !store.entries.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "Chưa có lịch sử. Các bản dịch, tóm tắt và giải thích hoàn tất sẽ xuất hiện ở đây.")
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -12).isActive = true
            return
        }

        for (index, entry) in store.entries.enumerated() {
            let formattedDate = Self.dateFormatter.string(from: entry.createdAt)
            let row = HistoryRowButton(entry: entry, formattedDate: formattedDate,
                                       target: self, action: #selector(selectEntry(_:)))
            row.isSelectedRow = (entry.id == selectedEntry?.id)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -12).isActive = true
            if index < store.entries.count - 1 {
                let divider = HistoryDividerView(axis: .horizontal)
                listStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -12).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }
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
        selectedEntry = entry
        for case let row as HistoryRowButton in listStack.arrangedSubviews {
            row.isSelectedRow = (row.identifier?.rawValue == idString)
        }
        detailTitle.stringValue = "\(entry.skill.displayName)"
        detailMeta.stringValue = "Thời gian: \(Self.dateFormatter.string(from: entry.createdAt))  |  Model: \(entry.model)\nNội dung gốc: \(entry.sourcePreview)"
        detailText.textStorage?.setAttributedString(MarkdownLite.attributed(entry.resultText))
        detailText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        copyButton.isEnabled = true
        deleteButton.isEnabled = true
        statusLabel.stringValue = ""
    }

    @objc private func copySelected() {
        guard let selectedEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedEntry.resultText, forType: .string)
        statusLabel.stringValue = "Đã sao chép kết quả."
    }

    @objc private func deleteSelected() {
        guard let selectedEntry else { return }
        do {
            try store.remove(id: selectedEntry.id)
            reload()
            statusLabel.stringValue = "Đã xóa mục khỏi lịch sử."
        } catch {
            statusLabel.stringValue = error.localizedDescription
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
            statusLabel.stringValue = "Đã xóa toàn bộ lịch sử."
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }
}
