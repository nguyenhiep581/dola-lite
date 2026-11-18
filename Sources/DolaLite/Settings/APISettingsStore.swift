import Foundation
import LocalAuthentication
import Security

@MainActor
protocol APIKeyStore {
    func read() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
}

@MainActor
final class KeychainAPIKeyStore: APIKeyStore {
    static let service = "com.hiep.dolalite.api"
    static let account = "api-key"

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func read() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // A background status check must never trigger a Keychain login prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APISettingsError.keychainFailure(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw APISettingsError.invalidCredentialData
        }
        return key
    }

    func save(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw APISettingsError.keychainFailure(addStatus) }
        } else if status != errSecSuccess {
            throw APISettingsError.keychainFailure(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APISettingsError.keychainFailure(status)
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
        self.keyStore = keyStore ?? KeychainAPIKeyStore()
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
    /// The fallible Keychain write precedes preferences, so a denied write changes neither.
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
