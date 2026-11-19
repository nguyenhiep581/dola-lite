import AppKit
import Testing
@testable import DolaLite

@MainActor
@Suite struct LaunchAtLoginTests {
    @Test func settingsCheckboxTogglesLaunchAtLoginAndRevertsOnFailure() {
        _ = NSApplication.shared
        let suite = "DolaLite.LaunchAtLoginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = APISettingsStore(defaults: defaults, keyStore: StubKeyStore())
        let controller = FakeLaunchAtLoginController(state: .disabled)
        let window = APISettingsWindow(store: store, launchAtLogin: controller)
        defer { window.close() }

        window.present()
        guard let checkbox = window.window?.contentView.flatMap({ findCheckbox(in: $0, title: "Khởi động Dola Lite cùng macOS") }) else {
            Issue.record("Expected launch-at-login checkbox in settings window")
            return
        }
        #expect(checkbox.state == .off)

        checkbox.performClick(checkbox)
        #expect(controller.state == .enabled)
        #expect(checkbox.state == .on)

        controller.nextError = .operationFailed
        checkbox.performClick(checkbox)
        #expect(controller.state == .enabled)
        #expect(checkbox.state == .on)

        controller.nextError = nil
        checkbox.performClick(checkbox)
        #expect(controller.state == .disabled)
        #expect(checkbox.state == .off)
    }

    private func findCheckbox(in view: NSView, title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = findCheckbox(in: subview, title: title) { return found }
        }
        return nil
    }
}

@MainActor
private final class FakeLaunchAtLoginController: LaunchAtLoginControlling {
    var state: LaunchAtLoginState
    var nextError: LaunchAtLoginError?
    var openedSettingsCount = 0

    init(state: LaunchAtLoginState) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        if let nextError { throw nextError }
        state = enabled ? .enabled : .disabled
    }

    func openSystemSettings() {
        openedSettingsCount += 1
    }
}

@MainActor
private final class StubKeyStore: APIKeyStore {
    var value: String? = "fixture-key"
    func read() throws -> String? { value }
    func save(_ apiKey: String) throws { value = apiKey }
    func delete() throws { value = nil }
}
