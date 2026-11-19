import AppKit

@MainActor
final class APISettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    private let store: APISettingsStore
    private let baseURLField = NSTextField()
    private let modelField = NSComboBox()
    // Ô text thường (không phải ô mật khẩu) để paste và kiểm tra key dài bằng mắt.
    private let keyField = NSTextField()
    private let effortPicker = NSPopUpButton()
    private let wirePicker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "Kiểm tra kết nối", target: nil, action: nil)
    private var testTask: Task<Void, Never>?
    private var testGeneration = UUID()
    private let refreshModelsButton = NSButton(title: "Tải model", target: nil, action: nil)
    private var modelFetchTask: Task<Void, Never>?
    private var modelFetchGeneration = UUID()
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?

    init(store: APISettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
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
        cancelModelFetch()
        let config = store.configuration
        baseURLField.stringValue = config.baseURL
        modelField.stringValue = config.model
        keyField.stringValue = ""
        effortPicker.selectItem(withTitle: config.reasoningEffort)
        wirePicker.selectItem(withTitle: Self.wireTitles[config.wireAPI] ?? APIConfiguration.chatWire)
        updateKeyPlaceholder()
        status.stringValue = store.initializationError ?? (store.hasAPIKey ? "API key đã được lưu trên máy (file riêng tư)." : "Chưa có API key. Nhập key để bắt đầu.")
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cancelConnectionTest()
        cancelModelFetch()
        keyField.stringValue = ""
        onClose?()
    }

    func controlTextDidChange(_ notification: Notification) {
        cancelConnectionTest()
        cancelModelFetch()
        status.stringValue = ""
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        cancelConnectionTest()
        status.stringValue = ""
    }

    @objc private func configurationOptionChanged() {
        cancelConnectionTest()
        status.stringValue = ""
    }

    private func cancelConnectionTest() {
        testGeneration = UUID()
        testTask?.cancel()
        testTask = nil
        testButton.isEnabled = true
    }

    private func cancelModelFetch() {
        modelFetchGeneration = UUID()
        modelFetchTask?.cancel()
        modelFetchTask = nil
        refreshModelsButton.isEnabled = true
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
        addModelField(to: stack)
        addField("API key", field: keyField, to: stack)
        wirePicker.addItems(withTitles: [Self.wireTitles[APIConfiguration.chatWire]!,
                                         Self.wireTitles[APIConfiguration.responsesWire]!])
        wirePicker.target = self
        wirePicker.action = #selector(configurationOptionChanged)
        let wireRow = NSStackView(views: [NSTextField(labelWithString: "Kiểu API"), wirePicker])
        wireRow.spacing = 12
        stack.addArrangedSubview(wireRow)
        effortPicker.addItems(withTitles: ["low", "medium", "high"])
        effortPicker.target = self
        effortPicker.action = #selector(configurationOptionChanged)
        let effortRow = NSStackView(views: [NSTextField(labelWithString: "Tóm tắt / Giải thích"), effortPicker])
        effortRow.spacing = 12
        stack.addArrangedSubview(effortRow)
        let note = NSTextField(wrappingLabelWithString: "Dịch luôn dùng mức low để ưu tiên tốc độ. Kiểm tra kết nối dùng cùng một đoạn dịch mẫu và tính tổng thời gian đến khi nhận xong; thời gian có thể dao động theo mạng và tải máy chủ. Để trống ô API key để giữ key đã lưu.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        status.font = .systemFont(ofSize: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(status)
        let deleteButton = NSButton(title: "Xóa API key", target: self, action: #selector(deleteKey))
        testButton.target = self
        testButton.action = #selector(testConnection)
        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(fetchModels)
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
        baseURLField.placeholderString = "https://integrate.api.nvidia.com/v1"
        modelField.placeholderString = "nvidia/nemotron-3.5-bolt-e4b"
        modelField.completes = false
        modelField.numberOfVisibleItems = 12
    }

    private func addModelField(to stack: NSStackView) {
        let title = NSTextField(labelWithString: "Model")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let row = NSStackView(views: [modelField, refreshModelsButton])
        row.spacing = 8
        row.distribution = .fill
        modelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refreshModelsButton.setContentHuggingPriority(.required, for: .horizontal)
        let group = NSStackView(views: [title, row])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        modelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
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

    private static let wireTitles = [APIConfiguration.chatWire: "Chat Completions",
                                     APIConfiguration.responsesWire: "Responses (Xingchi)"]

    private func draft() -> APIConfiguration {
        let wireTitle = wirePicker.titleOfSelectedItem ?? Self.wireTitles[APIConfiguration.chatWire]!
        let wire = Self.wireTitles.first { $0.value == wireTitle }?.key ?? APIConfiguration.chatWire
        return APIConfiguration(baseURL: baseURLField.stringValue,
                                model: modelField.stringValue,
                                reasoningEffort: effortPicker.titleOfSelectedItem ?? "high",
                                wireAPI: wire)
    }

    private func updateKeyPlaceholder() {
        keyField.placeholderString = store.hasAPIKey ? "Đã lưu key — nhập để thay" : "Nhập API key"
    }

    @objc private func save() {
        cancelConnectionTest()
        cancelModelFetch()
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
        cancelModelFetch()
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
        testGeneration = UUID()
        let generation = testGeneration
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
                let startedAt = ProcessInfo.processInfo.systemUptime
                defer {
                    if self.testGeneration == generation {
                        testButton.isEnabled = true
                        testTask = nil
                    }
                }
                do {
                    var received = false
                    let testText = "A clear, natural translation should preserve the original meaning while remaining concise and easy to understand."
                    for try await chunk in provider.stream(skill: .translate, text: testText) {
                        try Task.checkCancellation()
                        received = received || !chunk.isEmpty
                    }
                    guard !Task.isCancelled, self.testGeneration == generation else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                    let timing = String(format: "%.2f giây", locale: Locale.current, elapsed)
                    status.stringValue = received
                        ? "Kết nối thành công · tổng thời gian dịch mẫu: \(timing)."
                        : "API chưa trả nội dung · thời gian chờ: \(timing)."
                } catch {
                    guard !Task.isCancelled, self.testGeneration == generation else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                    let timing = String(format: "%.2f giây", locale: Locale.current, elapsed)
                    status.stringValue = "\(error.localizedDescription) · thời gian chờ: \(timing)."
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func fetchModels() {
        cancelModelFetch()
        let generation = modelFetchGeneration
        do {
            var config = draft()
            config.baseURL = try config.validatedBaseURL()
            let entered = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = entered.isEmpty ? try store.snapshot().apiKey : entered
            let snapshot = APICredentialsSnapshot(configuration: config, apiKey: key)
            refreshModelsButton.isEnabled = false
            status.stringValue = "Đang tải danh sách model…"
            modelFetchTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.modelFetchGeneration == generation {
                        refreshModelsButton.isEnabled = true
                        modelFetchTask = nil
                    }
                }
                do {
                    let models = try await APIModelCatalog.fetch(snapshot: snapshot)
                    guard !Task.isCancelled, self.modelFetchGeneration == generation else { return }
                    modelField.removeAllItems()
                    modelField.addItems(withObjectValues: models)
                    status.stringValue = models.isEmpty
                        ? "Endpoint chưa trả về model nào. Bạn vẫn có thể nhập model thủ công."
                        : "Đã tải \(models.count) model. Chọn trong danh sách hoặc nhập model thủ công."
                } catch {
                    guard !Task.isCancelled, self.modelFetchGeneration == generation else { return }
                    status.stringValue = error.localizedDescription
                }
            }
        } catch {
            status.stringValue = error.localizedDescription
        }
    }
}
