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
