import Foundation

@MainActor
protocol APIKeyStore {
    func read() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
}

/// Stores the API key in a plain 0600 file (same model as ~/.dsh credentials).
/// The app is ad-hoc signed and rebuilt often; a Keychain item would prompt
/// for access after every rebuild because the code signature changed.
@MainActor
final class FileAPIKeyStore: APIKeyStore {
    private let fileURL: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        let base = directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DolaLite", isDirectory: true)
        fileURL = base.appendingPathComponent("api-key")
    }

    func read() throws -> String? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
                throw APISettingsError.storageFailure
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= 1_048_576, let raw = String(data: data, encoding: .utf8) else {
                throw APISettingsError.storageFailure
            }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        } catch let error as APISettingsError {
            throw error
        } catch {
            throw APISettingsError.storageFailure
        }
    }

    func save(_ apiKey: String) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
            try Data(apiKey.utf8).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw APISettingsError.storageFailure
        }
    }

    func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw APISettingsError.storageFailure
        }
    }
}

@MainActor
final class APISettingsStore {
    static let configurationDefaultsKey = "api.configuration.v1"

    private let defaults: UserDefaults
    private let keyStore: any APIKeyStore
    private(set) var configuration: APIConfiguration
    private(set) var initializationError: String?

    init(defaults: UserDefaults = .standard,
         keyStore: (any APIKeyStore)? = nil) {
        self.defaults = defaults
        self.keyStore = keyStore ?? FileAPIKeyStore()
        if let data = defaults.data(forKey: Self.configurationDefaultsKey) {
            do {
                configuration = try JSONDecoder().decode(APIConfiguration.self, from: data).validated()
            } catch {
                configuration = APIConfiguration()
                initializationError = APISettingsError.invalidStoredConfiguration.localizedDescription
            }
        } else {
            configuration = APIConfiguration()
        }
    }

    var hasAPIKey: Bool {
        guard let key = try? keyStore.read() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func snapshot() throws -> APICredentialsSnapshot {
        let validated = try configuration.validated()
        guard let key = try keyStore.read(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APISettingsError.missingAPIKey
        }
        return APICredentialsSnapshot(configuration: validated, apiKey: try Self.validatedKey(key))
    }

    /// An empty key field keeps the existing key, allowing endpoint/model-only edits.
    /// The fallible key write precedes preferences, so a denied write changes neither.
    func save(configuration: APIConfiguration, apiKey: String) throws {
        let validated = try configuration.validated()
        let encoded = try JSONEncoder().encode(validated)
        let incoming = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if incoming.isEmpty {
            guard let existing = try keyStore.read() else { throw APISettingsError.missingAPIKey }
            _ = try Self.validatedKey(existing)
        } else {
            try keyStore.save(Self.validatedKey(incoming))
        }
        defaults.set(encoded, forKey: Self.configurationDefaultsKey)
        self.configuration = validated
        initializationError = nil
    }

    func deleteAPIKey() throws {
        try keyStore.delete()
        initializationError = nil
    }

    private static func validatedKey(_ key: String) throws -> String {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw APISettingsError.missingAPIKey }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APISettingsError.invalidAPIKey
        }
        return value
    }
}
