import Foundation

enum Skill: String, CaseIterable, Sendable {
    case translate, summarize, explain

    var displayName: String {
        switch self {
        case .translate: return "Dịch"
        case .summarize: return "Tóm tắt"
        case .explain: return "Giải thích"
        }
    }

    var systemPrompt: String {
        switch self {
        case .translate:
            return "Dịch văn bản người dùng sang tiếng Việt. Chỉ trả lời bằng bản dịch tiếng Việt, không thêm lời dẫn hoặc giải thích."
        case .summarize:
            return "Tóm tắt văn bản người dùng bằng tiếng Việt, ngắn gọn theo gạch đầu dòng. Chỉ trả lời bằng tiếng Việt."
        case .explain:
            return "Giải thích văn bản người dùng bằng tiếng Việt, ngắn gọn và dễ hiểu. Chỉ trả lời bằng tiếng Việt."
        }
    }
}

@MainActor
protocol AIProvider {
    func ensureReady() async throws
    func stream(skill: Skill, text: String) -> AsyncThrowingStream<String, Error>
}

enum APIProviderError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case forbidden
    case rateLimited
    case serverUnavailable
    case httpStatus(Int)
    case timeout
    case network
    case invalidResponse
    case malformedStream
    case responseTooLarge
    case serverError
    case emptyResponse
    case incompleteResponse
    case truncatedResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "API key không hợp lệ hoặc đã hết hạn. Hãy kiểm tra Cài đặt API."
        case .forbidden: return "Nhà cung cấp từ chối yêu cầu (HTTP 403). Hãy kiểm tra quyền của key, model và ứng dụng khách."
        case .rateLimited: return "Đã vượt giới hạn yêu cầu API. Vui lòng thử lại sau."
        case .serverUnavailable: return "Máy chủ API đang gặp sự cố. Vui lòng thử lại sau."
        case .httpStatus(let status): return "Yêu cầu API thất bại (HTTP \(status)). Hãy kiểm tra cấu hình API."
        case .timeout: return "Hết thời gian chờ phản hồi từ API. Vui lòng thử lại."
        case .network: return "Không thể kết nối đến API. Hãy kiểm tra mạng và địa chỉ API."
        case .invalidResponse: return "API trả về phản hồi không hợp lệ."
        case .malformedStream: return "Không đọc được luồng phản hồi từ API. Vui lòng thử lại."
        case .responseTooLarge: return "Luồng phản hồi từ API vượt giới hạn xử lý."
        case .serverError: return "API báo lỗi khi tạo phản hồi. Hãy kiểm tra cấu hình và thử lại."
        case .emptyResponse: return "API không trả về nội dung. Vui lòng thử lại."
        case .incompleteResponse: return "Kết nối API kết thúc trước khi phản hồi hoàn tất. Vui lòng thử lại."
        case .truncatedResponse: return "Phản hồi bị cắt do đạt giới hạn độ dài của model."
        }
    }

    static func status(_ code: Int) -> APIProviderError? {
        switch code {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403: return .forbidden
        case 429: return .rateLimited
        case 500..<600: return .serverUnavailable
        default: return .httpStatus(code)
        }
    }

    /// Never expose arbitrary transport diagnostics, which can contain URLs or credentials.
    static func safe(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? APIProviderError { return error }
        if let error = error as? APISettingsError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return CancellationError()
            case .timedOut: return APIProviderError.timeout
            default: return APIProviderError.network
            }
        }
        return APIProviderError.network
    }
}
