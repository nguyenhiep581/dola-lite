import AppKit
import Testing
@testable import DolaLite

@Suite(.serialized)
@MainActor
struct CoordinatorTests {
    @Test func replacementAndDismissIgnoreOldResponses() async throws {
        _ = NSApplication.shared
        let suite = "DolaLite.CoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = APISettingsStore(defaults: defaults, keyStore: CoordinatorKeyStore())
        let provider = ControlledProvider()
        let pill = PillPanel()
        let result = ResultPanel()
        let coordinator = PanelCoordinator(pill: pill, result: result, provider: provider, settings: settings, openSettings: {})
        defer { coordinator.shutdown() }
        pill.onSkillTap?(.translate, "first")
        for _ in 0..<100 where provider.streams.count < 1 { await Task.yield() }
        #expect(provider.streams.count == 1)
        guard provider.streams.count == 1 else { return }
        pill.onSkillTap?(.summarize, "second")
        for _ in 0..<100 where provider.streams.count < 2 { await Task.yield() }
        #expect(provider.streams.count == 2)
        guard provider.streams.count == 2 else { return }
        provider.streams[0].yield("obsolete")
        provider.streams[0].finish()
        provider.streams[1].yield("current")
        provider.streams[1].finish()
        for _ in 0..<100 where result.fullText != "current" { await Task.yield() }
        #expect(result.fullText == "current")
        coordinator.dismissAll()
        #expect(!result.isVisible)
        #expect(!pill.isVisible)
    }

    @Test func missingKeyOpensSettingsWithoutCallingProvider() {
        _ = NSApplication.shared
        let suite = "DolaLite.CoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = APISettingsStore(defaults: defaults, keyStore: CoordinatorKeyStore(value: nil))
        let provider = ControlledProvider()
        let pill = PillPanel()
        let result = ResultPanel()
        var opened = false
        let coordinator = PanelCoordinator(pill: pill, result: result, provider: provider, settings: settings, openSettings: { opened = true })
        defer { coordinator.shutdown() }
        pill.onSkillTap?(.translate, "hello")
        #expect(opened)
        #expect(provider.streams.isEmpty)
        #expect(!result.isVisible)
    }

    @Test func pinnedResultSurvivesSelectionChangesUntilExplicitDismissal() async {
        _ = NSApplication.shared
        let suite = "DolaLite.CoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = APISettingsStore(defaults: defaults, keyStore: CoordinatorKeyStore())
        let provider = ControlledProvider()
        let pill = PillPanel()
        let result = ResultPanel()
        let coordinator = PanelCoordinator(pill: pill, result: result, provider: provider, settings: settings, openSettings: {})
        defer { coordinator.shutdown() }

        coordinator.handleSelection(SelectionSnapshot(text: "first", bounds: nil, sourcePID: 101))
        pill.onSkillTap?(.translate, "first")
        for _ in 0..<100 where provider.streams.isEmpty { await Task.yield() }
        guard let pin = result.contentView.flatMap({ findButton(in: $0, label: "Giữ cửa sổ mở") }) else {
            Issue.record("Expected an accessible pin button")
            return
        }
        pin.performClick(pin)
        #expect(result.isPinned)

        coordinator.handleSelection(SelectionSnapshot(text: "second", bounds: nil, sourcePID: 102))
        #expect(result.isVisible)
        #expect(result.isPinned)
        #expect(pill.isVisible)

        // Starting a new task from the pill replaces the pinned result safely.
        pill.onSkillTap?(.explain, "second")
        for _ in 0..<100 where provider.streams.count < 2 { await Task.yield() }
        #expect(provider.streams.count == 2)
        #expect(!result.isPinned)
        coordinator.dismissAll()
        #expect(!result.isVisible)
    }

    @Test func completedResponsesAreSavedToLocalHistory() async throws {
        _ = NSApplication.shared
        let suite = "DolaLite.CoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = APISettingsStore(defaults: defaults, keyStore: CoordinatorKeyStore())
        let history = HistoryStore(directory: directory)
        let provider = ControlledProvider()
        let pill = PillPanel()
        let result = ResultPanel()
        let coordinator = PanelCoordinator(pill: pill, result: result, provider: provider,
                                           settings: settings, historyStore: history, openSettings: {})
        defer { coordinator.shutdown() }

        coordinator.handleSelection(SelectionSnapshot(text: "source", bounds: nil, sourcePID: 103))
        pill.onSkillTap?(.summarize, "source text")
        for _ in 0..<100 where provider.streams.isEmpty { await Task.yield() }
        guard let stream = provider.streams.first else {
            Issue.record("Expected the provider request to start")
            return
        }
        stream.yield("summary result")
        stream.finish()
        for _ in 0..<100 where history.entries.isEmpty { await Task.yield() }
        #expect(history.entries.count == 1)
        #expect(history.entries.first?.skill == .summarize)
        #expect(history.entries.first?.sourceText == "source text")
        #expect(history.entries.first?.resultText == "summary result")
        #expect(history.entries.first?.model == settings.configuration.model)
    }

    @Test func failedResponsesAreNotSavedToHistory() async throws {
        _ = NSApplication.shared
        let suite = "DolaLite.CoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(directory: directory)
        let provider = ControlledProvider()
        let pill = PillPanel()
        let result = ResultPanel()
        let coordinator = PanelCoordinator(pill: pill, result: result, provider: provider,
                                           settings: APISettingsStore(defaults: defaults, keyStore: CoordinatorKeyStore()),
                                           historyStore: history, openSettings: {})
        defer { coordinator.shutdown() }
        coordinator.handleSelection(SelectionSnapshot(text: "source", bounds: nil, sourcePID: 104))
        pill.onSkillTap?(.translate, "source")
        for _ in 0..<100 where provider.streams.isEmpty { await Task.yield() }
        provider.streams.first?.yield("partial result")
        provider.streams.first?.finish(throwing: APIProviderError.network)
        for _ in 0..<100 { await Task.yield() }
        #expect(history.entries.isEmpty)
    }

    @Test func retryPreservesMovedResultPanelFrame() async {
        _ = NSApplication.shared
        let suite = "DolaLite.CoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ControlledProvider()
        let pill = PillPanel()
        let result = ResultPanel()
        let coordinator = PanelCoordinator(pill: pill, result: result, provider: provider,
                                           settings: APISettingsStore(defaults: defaults, keyStore: CoordinatorKeyStore()),
                                           openSettings: {})
        defer { coordinator.shutdown() }

        pill.onSkillTap?(.explain, "Jira bug")
        for _ in 0..<100 where provider.streams.isEmpty { await Task.yield() }
        provider.streams.first?.finish(throwing: APIProviderError.network)
        for _ in 0..<100 where !result.isVisible { await Task.yield() }

        let customOrigin = NSPoint(x: result.frame.minX + 60, y: result.frame.minY + 40)
        result.setFrameOrigin(customOrigin)
        let expectedFrame = result.frame

        result.onRetry?()
        for _ in 0..<100 where provider.streams.count < 2 { await Task.yield() }
        #expect(provider.streams.count == 2)
        #expect(result.frame == expectedFrame)
    }

    private func findButton(in view: NSView, label: String) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityLabel() == label { return button }
        for subview in view.subviews {
            if let found = findButton(in: subview, label: label) { return found }
        }
        return nil
    }
}

@MainActor
private final class CoordinatorKeyStore: APIKeyStore {
    var value: String?
    init(value: String? = "fixture-key") { self.value = value }
    func read() throws -> String? { value }
    func save(_ apiKey: String) throws { value = apiKey }
    func delete() throws { value = nil }
}

@MainActor
private final class ControlledProvider: AIProvider {
    var streams: [AsyncThrowingStream<String, Error>.Continuation] = []
    func ensureReady() async throws {}
    func stream(skill: Skill, text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { streams.append($0) }
    }
}
