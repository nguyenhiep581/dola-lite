import AppKit

@MainActor
final class APISettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    private let store: APISettingsStore
    private let launchAtLogin: LaunchAtLoginControlling?
    private let baseURLField = NSTextField()
    private let modelField = NSComboBox()
    // Ô text thường (không phải ô mật khẩu) để paste và kiểm tra key dài bằng mắt.
    private let keyField = NSTextField()
    private let effortPicker = NSPopUpButton()
    private let wirePicker = NSPopUpButton()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Khởi động Dola Lite cùng macOS", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "Kiểm tra kết nối", target: nil, action: nil)
    private var testTask: Task<Void, Never>?
    private var testGeneration = UUID()
    private let refreshModelsButton = NSButton(title: "Tải model", target: nil, action: nil)
    private var modelFetchTask: Task<Void, Never>?
    private var modelFetchGeneration = UUID()
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?

    init(store: APISettingsStore, launchAtLogin: LaunchAtLoginControlling? = nil) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
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
        syncLaunchAtLoginCheckbox()
        updateKeyPlaceholder()
        if let initError = store.initializationError {
            setStatus(initError, color: .systemOrange)
        } else if !store.hasAPIKey {
            setStatus("Chưa có API key. Nhập key để bắt đầu.", color: .secondaryLabelColor)
        } else {
            setStatus("", color: .secondaryLabelColor)
        }
        fitWindowToContent()
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
        setStatus("", color: .secondaryLabelColor)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        cancelConnectionTest()
        setStatus("", color: .secondaryLabelColor)
    }

    @objc private func configurationOptionChanged() {
        cancelConnectionTest()
        setStatus("", color: .secondaryLabelColor)
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

    private func setStatus(_ message: String, color: NSColor) {
        let wasHidden = status.isHidden
        status.stringValue = message
        status.textColor = color
        status.isHidden = message.isEmpty
        if wasHidden != status.isHidden || !message.isEmpty {
            fitWindowToContent()
        }
    }

    private func fitWindowToContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let targetHeight = max(280, ceil(fitting.height))
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 480, height: targetHeight))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        if abs(window.frame.height - frame.height) > 1 || abs(window.frame.width - frame.width) > 1 {
            window.setFrame(frame, display: true)
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 480)
        ])

        let formCard = AdaptiveSurfaceView(frame: .zero)
        formCard.cornerRadius = 10
        formCard.borderWidth = 1
        formCard.fillColor = { DesignTokens.Colors.cardSurface }

        let formStack = NSStackView()
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formCard.addSubview(formStack)
        NSLayoutConstraint.activate([
            formStack.leadingAnchor.constraint(equalTo: formCard.leadingAnchor, constant: 14),
            formStack.trailingAnchor.constraint(equalTo: formCard.trailingAnchor, constant: -14),
            formStack.topAnchor.constraint(equalTo: formCard.topAnchor, constant: 12),
            formStack.bottomAnchor.constraint(equalTo: formCard.bottomAnchor, constant: -12)
        ])

        addField("Base URL", field: baseURLField, to: formStack)
        addModelField(to: formStack)
        addField("API key", field: keyField, to: formStack)

        wirePicker.addItems(withTitles: [Self.wireTitles[APIConfiguration.chatWire]!,
                                         Self.wireTitles[APIConfiguration.responsesWire]!])
        wirePicker.target = self
        wirePicker.action = #selector(configurationOptionChanged)

        effortPicker.addItems(withTitles: ["low", "medium", "high"])
        effortPicker.target = self
        effortPicker.action = #selector(configurationOptionChanged)

        let wireGroup = makePickerGroup(label: "Kiểu API", picker: wirePicker)
        let effortGroup = makePickerGroup(label: "Tóm tắt / Giải thích", picker: effortPicker)
        let optionsRow = NSStackView(views: [wireGroup, effortGroup])
        optionsRow.orientation = .horizontal
        optionsRow.distribution = .fillEqually
        optionsRow.spacing = 12
        formStack.addArrangedSubview(optionsRow)
        optionsRow.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true

        root.addArrangedSubview(formCard)
        formCard.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        if launchAtLogin != nil {
            launchAtLoginCheckbox.font = .systemFont(ofSize: 12)
            launchAtLoginCheckbox.target = self
            launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
            root.addArrangedSubview(launchAtLoginCheckbox)
        }

        let note = NSTextField(wrappingLabelWithString: "Dịch luôn dùng mức low để ưu tiên tốc độ. Để trống API key để giữ key đã lưu.")
        note.font = DesignTokens.Typography.caption
        note.textColor = .tertiaryLabelColor
        root.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        status.font = .systemFont(ofSize: 11.5)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.isHidden = true
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let footerDivider = HistoryDividerView(axis: .horizontal)
        root.addArrangedSubview(footerDivider)
        footerDivider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        footerDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let deleteButton = NSButton(title: "Xóa key", target: self, action: #selector(deleteKey))
        testButton.target = self
        testButton.action = #selector(testConnection)
        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(fetchModels)
        let cancel = NSButton(title: "Hủy", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Lưu", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.bezelColor = .controlAccentColor

        let footerSpacer = NSView()
        let footerRow = NSStackView(views: [deleteButton, testButton, footerSpacer, cancel, save])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8
        root.addArrangedSubview(footerRow)
        footerRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        baseURLField.delegate = self
        modelField.delegate = self
        keyField.delegate = self
        baseURLField.placeholderString = "https://integrate.api.nvidia.com/v1"
        modelField.placeholderString = "nvidia/nemotron-3.5-bolt-e4b"
        modelField.completes = false
        modelField.numberOfVisibleItems = 12
    }

    private func makePickerGroup(label: String, picker: NSPopUpButton) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = .secondaryLabelColor
        let group = NSStackView(views: [title, picker])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        picker.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func addModelField(to stack: NSStackView) {
        let title = NSTextField(labelWithString: "Model")
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = .secondaryLabelColor
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
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = .secondaryLabelColor
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
        keyField.placeholderString = store.hasAPIKey ? "Đã lưu key trên máy — nhập để thay đổi" : "Nhập API key"
    }

    private func syncLaunchAtLoginCheckbox() {
        guard let launchAtLogin else { return }
        launchAtLoginCheckbox.state = launchAtLogin.isEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        guard let launchAtLogin else { return }
        let target = launchAtLoginCheckbox.state == .on
        do {
            try launchAtLogin.setEnabled(target)
            syncLaunchAtLoginCheckbox()
            setStatus(target ? "Đã bật khởi động cùng macOS." : "Đã tắt khởi động cùng macOS.",
                      color: .secondaryLabelColor)
            onSave?()
        } catch let error as LaunchAtLoginError where error == .requiresApproval {
            syncLaunchAtLoginCheckbox()
            setStatus(error.localizedDescription, color: .systemOrange)
            launchAtLogin.openSystemSettings()
        } catch {
            syncLaunchAtLoginCheckbox()
            setStatus(error.localizedDescription, color: .systemRed)
        }
    }

    @objc private func save() {
        cancelConnectionTest()
        cancelModelFetch()
        do {
            try store.save(configuration: draft(), apiKey: keyField.stringValue)
            keyField.stringValue = ""
            onSave?()
            window?.close()
        } catch { setStatus(error.localizedDescription, color: .systemRed) }
    }

    @objc private func cancel() { window?.close() }

    @objc private func deleteKey() {
        cancelConnectionTest()
        cancelModelFetch()
        do {
            try store.deleteAPIKey()
            keyField.stringValue = ""
            updateKeyPlaceholder()
            setStatus("Đã xóa API key. Nhập key mới rồi bấm Lưu.", color: .secondaryLabelColor)
            onSave?()
        } catch { setStatus(error.localizedDescription, color: .systemRed) }
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
            setStatus("Đang gửi yêu cầu kiểm tra nhỏ…", color: .secondaryLabelColor)
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
                    if received {
                        setStatus("Kết nối thành công — tổng thời gian dịch mẫu: \(timing).", color: .systemGreen)
                    } else {
                        setStatus("API chưa trả nội dung — thời gian chờ: \(timing).", color: .systemOrange)
                    }
                } catch {
                    guard !Task.isCancelled, self.testGeneration == generation else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                    let timing = String(format: "%.2f giây", locale: Locale.current, elapsed)
                    setStatus("\(error.localizedDescription) (chờ \(timing)).", color: .systemRed)
                }
            }
        } catch { setStatus(error.localizedDescription, color: .systemRed) }
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
            setStatus("Đang tải danh sách model…", color: .secondaryLabelColor)
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
                    if models.isEmpty {
                        setStatus("Endpoint chưa trả về model nào. Bạn vẫn có thể nhập thủ công.", color: .systemOrange)
                    } else {
                        setStatus("Đã tải \(models.count) model — chọn trong danh sách hoặc nhập thủ công.", color: .systemGreen)
                    }
                } catch {
                    guard !Task.isCancelled, self.modelFetchGeneration == generation else { return }
                    setStatus(error.localizedDescription, color: .systemRed)
                }
            }
        } catch {
            setStatus(error.localizedDescription, color: .systemRed)
        }
    }
}
