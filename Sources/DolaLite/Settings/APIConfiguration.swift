import Foundation

struct APIConfiguration: Codable, Equatable, Sendable {
    static let chatWire = "chat"
    static let responsesWire = "responses"

    var baseURL: String = "https://integrate.api.nvidia.com/v1"
    var model: String = "nvidia/nemotron-3.5-bolt-e4b"
    var reasoningEffort: String = "high"
    /// "chat" = OpenAI Chat Completions (NVIDIA NIM, api.openai.com, …);
    /// "responses" = OpenAI Responses API (Xingchi relay yêu cầu dạng này).
    var wireAPI: String = APIConfiguration.chatWire

    private enum CodingKeys: String, CodingKey {
        case baseURL, model, reasoningEffort, wireAPI
    }

    init() {}

    init(baseURL: String = "https://integrate.api.nvidia.com/v1",
         model: String = "nvidia/nemotron-3.5-bolt-e4b",
         reasoningEffort: String = "high",
         wireAPI: String = APIConfiguration.chatWire) {
        self.baseURL = baseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.wireAPI = wireAPI
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://integrate.api.nvidia.com/v1"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "nvidia/nemotron-3.5-bolt-e4b"
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "high"
        // Config cũ (Xingchi era) không có trường này — mặc định responses để
        // cấu hình đã lưu của relay cũ vẫn chạy đúng sau khi nâng cấp.
        wireAPI = try container.decodeIfPresent(String.self, forKey: .wireAPI) ?? APIConfiguration.responsesWire
    }

    func validatedBaseURL() throws -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.url != nil,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APISettingsError.invalidBaseURL
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    func validated() throws -> APIConfiguration {
        var result = self
        result.baseURL = try validatedBaseURL()
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.reasoningEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !result.model.isEmpty,
              !result.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APISettingsError.invalidModel
        }
        guard [Self.chatWire, Self.responsesWire].contains(result.wireAPI) else {
            throw APISettingsError.invalidWireAPI
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
    case invalidWireAPI
    case missingAPIKey
    case invalidAPIKey
    case invalidStoredConfiguration
    case storageFailure
    case invalidCredentialData

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Địa chỉ API phải là URL HTTP hoặc HTTPS hợp lệ, không chứa tài khoản, query hay fragment."
        case .invalidModel:
            return "Tên model không được để trống hoặc chứa ký tự điều khiển."
        case .invalidReasoningEffort:
            return "Mức suy luận phải là low, medium hoặc high."
        case .invalidWireAPI:
            return "Kiểu API phải là Chat Completions hoặc Responses."
        case .missingAPIKey:
            return "Chưa có API key. Hãy mở Cài đặt API để nhập key."
        case .invalidAPIKey:
            return "API key không hợp lệ. Hãy nhập lại key trong Cài đặt API."
        case .invalidStoredConfiguration:
            return "Không đọc được cấu hình API đã lưu. Đang dùng cấu hình mặc định."
        case .storageFailure:
            return "Không đọc/ghi được file lưu API key. Hãy thử lại."
        case .invalidCredentialData:
            return "API key đã lưu không đọc được. Hãy lưu lại key trong Cài đặt API."
        }
    }
}
