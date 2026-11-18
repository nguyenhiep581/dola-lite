import Foundation
import Testing
@testable import DolaLite

@Suite struct SettingsConfigurationTests {
    @Test func trimsAndNormalizesValidConfiguration() throws {
        let value = try APIConfiguration(baseURL: " https://api.example.test/v1///\n",
                                         model: " sample-model ", reasoningEffort: " LOW ").validated()
        #expect(value == APIConfiguration(baseURL: "https://api.example.test/v1", model: "sample-model", reasoningEffort: "low"))
    }

    @Test(arguments: ["", "example.test/v1", "file:///tmp/key", "https://user:pass@example.test/v1",
                      "https://example.test/v1?key=fixture", "https://example.test/v1#fragment"])
    func rejectsInvalidBaseURL(_ url: String) {
        #expect(throws: APISettingsError.invalidBaseURL) { try APIConfiguration(baseURL: url).validated() }
    }

    @Test func rejectsEmptyModelAndUnknownReasoning() {
        #expect(throws: APISettingsError.invalidModel) { try APIConfiguration(model: " \n ").validated() }
        #expect(throws: APISettingsError.invalidReasoningEffort) { try APIConfiguration(reasoningEffort: "ultra").validated() }
    }

    @Test func configurationCodableRoundTrip() throws {
        let original = APIConfiguration(baseURL: "http://localhost:8123/v1", model: "fixture", reasoningEffort: "medium")
        #expect(try JSONDecoder().decode(APIConfiguration.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func rejectsUnknownWireAPI() {
        #expect(throws: APISettingsError.invalidWireAPI) {
            try APIConfiguration(wireAPI: "graphql").validated()
        }
    }

    @Test func decodingLegacyConfigWithoutWireDefaultsToResponses() throws {
        // Cấu hình đã lưu từ thời relay Xingchi (không có wireAPI) vẫn phải
        // chạy đúng endpoint /responses sau khi nâng cấp.
        let legacy = Data(#"{"baseURL":"https://api.xingchiapi.com/v1","model":"gpt-6.1-sol","reasoningEffort":"high"}"#.utf8)
        let decoded = try JSONDecoder().decode(APIConfiguration.self, from: legacy)
        #expect(decoded.wireAPI == APIConfiguration.responsesWire)
        #expect(decoded.baseURL == "https://api.xingchiapi.com/v1")
    }

    @Test func freshDefaultsTargetNvidiaChatWire() throws {
        let config = try APIConfiguration().validated()
        #expect(config.baseURL == "https://integrate.api.nvidia.com/v1")
        #expect(config.model == "nvidia/nemotron-3.5-bolt-e4b")
        #expect(config.wireAPI == APIConfiguration.chatWire)
    }
}

@MainActor
@Suite struct SettingsStoreTests {
    /// UserDefaults backed only by memory: writes never reach cfprefsd, so
    /// test runs can't leave `DolaLite.SettingsTests` plists in
    /// ~/Library/Preferences (suite-based defaults re-create their plist via
    /// asynchronous daemon flush even after `removePersistentDomain`).
    private func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        try body(InMemoryDefaults())
    }

    @Test func savePersistsConfigurationAndKeyAndRestores() throws {
        try withIsolatedDefaults { defaults in
            let keys = MemoryAPIKeyStore()
            let store = APISettingsStore(defaults: defaults, keyStore: keys)
            let value = APIConfiguration(model: "new-model", reasoningEffort: "medium")
            try store.save(configuration: value, apiKey: " fixture-new ")
            let restored = APISettingsStore(defaults: defaults, keyStore: keys)
            #expect(restored.configuration == value)
            #expect(try restored.snapshot().apiKey == "fixture-new")
            #expect(keys.saveCount == 1)
            #expect(restored.hasAPIKey)
        }
    }

    @Test func storageFailureLeavesConfigurationUntouched() throws {
        try withIsolatedDefaults { defaults in
            let keys = MemoryAPIKeyStore()
            let store = APISettingsStore(defaults: defaults, keyStore: keys)
            keys.writeError = .storageFailure
            #expect(throws: APISettingsError.storageFailure) {
                try store.save(configuration: APIConfiguration(model: "replacement"), apiKey: "fixture")
            }
            #expect(store.configuration == APIConfiguration())
            #expect(defaults.data(forKey: APISettingsStore.configurationDefaultsKey) == nil)
        }
    }

    @Test func invalidConfigurationDoesNotTouchKeyStore() {
        withIsolatedDefaults { defaults in
            let keys = MemoryAPIKeyStore()
            let store = APISettingsStore(defaults: defaults, keyStore: keys)
            #expect(throws: APISettingsError.invalidModel) {
                try store.save(configuration: APIConfiguration(model: ""), apiKey: "fixture")
            }
            #expect(keys.saveCount == 0)
        }
    }

    @Test func emptyKeyFieldKeepsExistingKey() throws {
        try withIsolatedDefaults { defaults in
            let keys = MemoryAPIKeyStore(key: "existing-fixture")
            let store = APISettingsStore(defaults: defaults, keyStore: keys)
            try store.save(configuration: APIConfiguration(reasoningEffort: "low"), apiKey: " ")
            #expect(try store.snapshot().apiKey == "existing-fixture")
            #expect(keys.saveCount == 0)
            #expect(store.configuration.reasoningEffort == "low")
        }
    }

    @Test func missingOrInvalidKeyCannotProduceSnapshotOrSave() {
        withIsolatedDefaults { defaults in
            let keys = MemoryAPIKeyStore()
            let store = APISettingsStore(defaults: defaults, keyStore: keys)
            #expect(throws: APISettingsError.missingAPIKey) { try store.snapshot() }
            #expect(throws: APISettingsError.missingAPIKey) { try store.save(configuration: APIConfiguration(), apiKey: "") }
            #expect(throws: APISettingsError.invalidAPIKey) {
                try store.save(configuration: APIConfiguration(), apiKey: "fixture\r\ninjected")
            }
            #expect(!store.hasAPIKey)
        }
    }

    @Test func deleteRemovesKeyButKeepsConfiguration() throws {
        try withIsolatedDefaults { defaults in
            let keys = MemoryAPIKeyStore(key: "existing-fixture")
            let store = APISettingsStore(defaults: defaults, keyStore: keys)
            try store.save(configuration: APIConfiguration(model: "kept-model"), apiKey: "fixture")
            try store.deleteAPIKey()
            #expect(!store.hasAPIKey)
            #expect(store.configuration == APIConfiguration(model: "kept-model"))
            #expect(throws: APISettingsError.missingAPIKey) { try store.snapshot() }
        }
    }

    @Test func failedDeleteRetainsKey() throws {
        try withIsolatedDefaults { defaults in
            let keys = MemoryAPIKeyStore(key: "existing-fixture")
            keys.deleteError = .storageFailure
            let store = APISettingsStore(defaults: defaults, keyStore: keys)
            #expect(throws: APISettingsError.storageFailure) { try store.deleteAPIKey() }
            #expect(store.hasAPIKey)
        }
    }

    @Test func corruptPreferencesUseDefaultsAndReportSafeError() {
        withIsolatedDefaults { defaults in
            defaults.set(Data("not-json".utf8), forKey: APISettingsStore.configurationDefaultsKey)
            let store = APISettingsStore(defaults: defaults, keyStore: MemoryAPIKeyStore())
            #expect(store.configuration == APIConfiguration())
            #expect(store.initializationError == APISettingsError.invalidStoredConfiguration.localizedDescription)
        }
    }
}

@MainActor
private final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value }
    override func removeObject(forKey defaultName: String) { storage[defaultName] = nil }
}

@MainActor
private final class MemoryAPIKeyStore: APIKeyStore {
    var key: String?
    var readError: APISettingsError?
    var writeError: APISettingsError?
    var deleteError: APISettingsError?
    var saveCount = 0

    init(key: String? = nil) { self.key = key }
    func read() throws -> String? {
        if let readError { throw readError }
        return key
    }
    func save(_ apiKey: String) throws {
        if let writeError { throw writeError }
        key = apiKey
        saveCount += 1
    }
    func delete() throws {
        if let deleteError { throw deleteError }
        key = nil
    }
}

@MainActor
@Suite struct FileAPIKeyStoreTests {
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DolaLite-FileAPIKeyStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func missingFileReadsNilAndDeleteIsNoop() throws {
        try withTempDirectory { directory in
            let store = FileAPIKeyStore(directory: directory)
            #expect(try store.read() == nil)
            try store.delete()
            #expect(try store.read() == nil)
        }
    }

    @Test func roundTripTrimsAndSetsOwnerOnlyPermissions() throws {
        try withTempDirectory { directory in
            let store = FileAPIKeyStore(directory: directory)
            try store.save(" fixture-key \n")
            #expect(try store.read() == "fixture-key")
            let file = directory.appendingPathComponent("api-key")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(mode & 0o777 == 0o600)
            try store.delete()
            #expect(try store.read() == nil)
        }
    }
}
