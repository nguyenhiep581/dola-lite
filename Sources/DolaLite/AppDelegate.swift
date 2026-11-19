import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var configurationItem: NSMenuItem!
    private let settings = APISettingsStore()
    private let historyStore = HistoryStore()
    private var settingsWindow: APISettingsWindow!
    private var historyWindow: HistoryWindowController!
    private var watcher: SelectionWatcher!
    private var coordinator: PanelCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsWindow = APISettingsWindow(store: settings)
        historyWindow = HistoryWindowController(store: historyStore)
        let provider = OpenAIProvider(configuration: { [settings] in try settings.snapshot() })
        coordinator = PanelCoordinator(pill: PillPanel(), result: ResultPanel(historyStore: historyStore),
                                       provider: provider, settings: settings,
                                       historyStore: historyStore,
                                       openSettings: { [weak self] in self?.showSettings() })
        watcher = SelectionWatcher()
        watcher.onSelection = { [weak self] in self?.coordinator.handleSelection($0) }
        settingsWindow.onClose = { [weak self] in self?.coordinator.resume() }
        settingsWindow.onSave = { [weak self] in self?.updateStatus() }
        buildMenu()
        updateStatus()
        watcher.start()
        AccessibilityOnboarding.showPromptIfNeeded()
        if !settings.hasAPIKey { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        coordinator?.shutdown()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Dola Lite")
        let menu = NSMenu()
        menu.addItem(withTitle: "Dola Lite", action: nil, keyEquivalent: "")
        configurationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(configurationItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Cài đặt API…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let historyItem = NSMenuItem(title: "Lịch sử…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let accessibilityItem = NSMenuItem(title: "Kiểm tra quyền Trợ năng…", action: #selector(checkAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Thoát", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func updateStatus() {
        configurationItem?.title = settings.hasAPIKey ? "API đã cấu hình · \(settings.configuration.model)" : "Chưa cấu hình API key"
    }

    @objc private func showSettings() {
        coordinator?.suspend()
        settingsWindow.present()
    }

    @objc private func checkAccessibility() {
        if AccessibilityOnboarding.isGranted() {
            let alert = NSAlert()
            alert.messageText = "Đã bật quyền Trợ năng"
            alert.informativeText = "Bạn có thể chọn văn bản trong ứng dụng khác để dùng Dola Lite."
            alert.addButton(withTitle: "Đóng")
            alert.runModal()
        } else {
            AccessibilityOnboarding.openSettings()
        }
    }

    @objc private func showHistory() {
        historyWindow.present()
    }
}
