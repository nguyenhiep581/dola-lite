import AppKit

@MainActor
final class APISettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let store: APISettingsStore
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    // Ô text thường (không phải ô mật khẩu) để paste và kiểm tra key dài bằng mắt.
    private let keyField = NSTextField()
    private let effortPicker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "Kiểm tra kết nối", target: nil, action: nil)
    private var testTask: Task<Void, Never>?
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?

    init(store: APISettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cài đặt API — Dola Lite"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        cancelConnectionTest()
        let config = store.configuration
        baseURLField.stringValue = config.baseURL
        modelField.stringValue = config.model
        keyField.stringValue = ""
        effortPicker.selectItem(withTitle: config.reasoningEffort)
        updateKeyPlaceholder()
        status.stringValue = store.initializationError ?? (store.hasAPIKey ? "API key đã được lưu trong Keychain." : "Chưa có API key. Nhập key để bắt đầu.")
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cancelConnectionTest()
        keyField.stringValue = ""
        onClose?()
    }

    func controlTextDidChange(_ notification: Notification) {
        cancelConnectionTest()
        status.stringValue = ""
    }

    private func cancelConnectionTest() {
        testTask?.cancel()
        testTask = nil
        testButton.isEnabled = true
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])
        let subtitle = NSTextField(wrappingLabelWithString: "Cấu hình riêng cho Dola Lite. Mỗi lần gọi dùng thiết lập đã lưu gần nhất.")
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        addField("Base URL", field: baseURLField, to: stack)
        addField("Model", field: modelField, to: stack)
        addField("API key", field: keyField, to: stack)
        effortPicker.addItems(withTitles: ["low", "medium", "high"])
        let effortRow = NSStackView(views: [NSTextField(labelWithString: "Tóm tắt / Giải thích"), effortPicker])
        effortRow.spacing = 12
        stack.addArrangedSubview(effortRow)
        let note = NSTextField(wrappingLabelWithString: "Dịch luôn dùng mức low để ưu tiên tốc độ. Để trống ô API key để giữ key đã lưu.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        status.font = .systemFont(ofSize: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(status)
        let deleteButton = NSButton(title: "Xóa API key", target: self, action: #selector(deleteKey))
        testButton.target = self
        testButton.action = #selector(testConnection)
        let cancel = NSButton(title: "Hủy", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Lưu", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let row = NSStackView(views: [deleteButton, testButton, cancel, save])
        row.spacing = 8
        stack.addArrangedSubview(row)
        for view in [subtitle, note, status] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        baseURLField.delegate = self
        modelField.delegate = self
        keyField.delegate = self
        baseURLField.placeholderString = "https://api.xingchiapi.com/v1"
        modelField.placeholderString = "gpt-6.1-sol"
    }

    private func addField(_ label: String, field: NSTextField, to stack: NSStackView) {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let group = NSStackView(views: [title, field])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        field.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
    }

    private func draft() -> APIConfiguration {
        APIConfiguration(baseURL: baseURLField.stringValue,
                         model: modelField.stringValue,
                         reasoningEffort: effortPicker.titleOfSelectedItem ?? "high")
    }

    private func updateKeyPlaceholder() {
        keyField.placeholderString = store.hasAPIKey ? "Đã lưu key — nhập để thay" : "Nhập API key"
    }

    @objc private func save() {
        cancelConnectionTest()
        do {
            try store.save(configuration: draft(), apiKey: keyField.stringValue)
            keyField.stringValue = ""
            onSave?()
            window?.close()
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func cancel() { window?.close() }

    @objc private func deleteKey() {
        cancelConnectionTest()
        do {
            try store.deleteAPIKey()
            keyField.stringValue = ""
            updateKeyPlaceholder()
            status.stringValue = "Đã xóa API key. Nhập key mới rồi bấm Lưu."
            onSave?()
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func testConnection() {
        testTask?.cancel()
        do {
            let config = try draft().validated()
            let entered = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = entered.isEmpty ? try store.snapshot().apiKey : entered
            let snapshot = APICredentialsSnapshot(configuration: config, apiKey: key)
            let provider = OpenAIProvider(configuration: { snapshot })
            testButton.isEnabled = false
            status.stringValue = "Đang gửi yêu cầu kiểm tra nhỏ…"
            testTask = Task { [weak self] in
                guard let self else { return }
                defer { testButton.isEnabled = true }
                do {
                    var received = false
                    for try await chunk in provider.stream(skill: .translate, text: "Hello.") {
                        try Task.checkCancellation()
                        received = received || !chunk.isEmpty
                    }
                    guard !Task.isCancelled else { return }
                    status.stringValue = received ? "Kết nối thành công. API đã trả kết quả." : "API chưa trả nội dung."
                } catch {
                    guard !Task.isCancelled else { return }
                    status.stringValue = error.localizedDescription
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
}
