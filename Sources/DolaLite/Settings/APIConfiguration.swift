import Foundation

struct APIConfiguration: Codable, Equatable, Sendable {
    var baseURL: String = "https://api.xingchiapi.com/v1"
    var model: String = "gpt-6.1-sol"
    var reasoningEffort: String = "high"

    func validated() throws -> APIConfiguration {
        var result = self
        result.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.reasoningEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let components = URLComponents(string: result.baseURL),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.url != nil,
              !result.baseURL.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APISettingsError.invalidBaseURL
        }
        while result.baseURL.hasSuffix("/") { result.baseURL.removeLast() }
        guard !result.model.isEmpty,
              !result.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APISettingsError.invalidModel
        }
        guard ["low", "medium", "high"].contains(result.reasoningEffort) else {
            throw APISettingsError.invalidReasoningEffort
        }
        return result
    }
}

struct APICredentialsSnapshot: Sendable {
    let configuration: APIConfiguration
    let apiKey: String
}

enum APISettingsError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidModel
    case invalidReasoningEffort
    case missingAPIKey
    case invalidAPIKey
    case invalidStoredConfiguration
    case keychainFailure(Int32)
    case invalidCredentialData

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Địa chỉ API phải là URL HTTP hoặc HTTPS hợp lệ, không chứa tài khoản, query hay fragment."
        case .invalidModel:
            return "Tên model không được để trống hoặc chứa ký tự điều khiển."
        case .invalidReasoningEffort:
            return "Mức suy luận phải là low, medium hoặc high."
        case .missingAPIKey:
            return "Chưa có API key. Hãy mở Cài đặt API để nhập key."
        case .invalidAPIKey:
            return "API key không hợp lệ. Hãy nhập lại key trong Cài đặt API."
        case .invalidStoredConfiguration:
            return "Không đọc được cấu hình API đã lưu. Đang dùng cấu hình mặc định."
        case .keychainFailure(let status):
            return "Không truy cập được API key trong Keychain (mã \(status)). Hãy thử lại."
        case .invalidCredentialData:
            return "API key trong Keychain không đọc được. Hãy lưu lại key trong Cài đặt API."
        }
    }
}
