import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var configurationItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private let settings = APISettingsStore()
    private let historyStore = HistoryStore()
    private let launchAtLogin: LaunchAtLoginControlling = SystemLaunchAtLoginController()
    private var settingsWindow: APISettingsWindow!
    private var historyWindow: HistoryWindowController!
    private var watcher: SelectionWatcher!
    private var coordinator: PanelCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsWindow = APISettingsWindow(store: settings, launchAtLogin: launchAtLogin)
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
        menu.delegate = self
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
        launchAtLoginItem = NSMenuItem(title: "Khởi động cùng macOS", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        let accessibilityItem = NSMenuItem(title: "Kiểm tra quyền Trợ năng…", action: #selector(checkAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Thoát", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateLaunchAtLoginMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
        updateLaunchAtLoginMenuState()
    }

    private func updateStatus() {
        configurationItem?.title = settings.hasAPIKey ? "API đã cấu hình · \(settings.configuration.model)" : "Chưa cấu hình API key"
        updateLaunchAtLoginMenuState()
    }

    private func updateLaunchAtLoginMenuState() {
        launchAtLoginItem?.state = launchAtLogin.isEnabled ? .on : .off
        launchAtLoginItem?.title = launchAtLogin.state == .requiresApproval
            ? "Khởi động cùng macOS (chờ xác nhận…)"
            : "Khởi động cùng macOS"
    }

    @objc private func toggleLaunchAtLogin() {
        let target = !launchAtLogin.isEnabled
        do {
            try launchAtLogin.setEnabled(target)
        } catch let error as LaunchAtLoginError where error == .requiresApproval {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Cần xác nhận Khởi động cùng macOS"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Mở Cài đặt hệ thống")
            alert.addButton(withTitle: "Đóng")
            if alert.runModal() == .alertFirstButtonReturn {
                launchAtLogin.openSystemSettings()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Không thể cập nhật Khởi động cùng macOS"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Đóng")
            alert.runModal()
        }
        updateLaunchAtLoginMenuState()
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
