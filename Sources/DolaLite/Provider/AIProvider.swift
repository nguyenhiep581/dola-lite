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
            return """
            You are an expert English-Vietnamese translator.

            Translate the user's text naturally.

            Requirements:
            - The source text may be in any language; always translate it into Vietnamese.
            - Preserve the original meaning.
            - Use natural, fluent Vietnamese.
            - Avoid literal word-by-word translation.
            - Preserve technical terminology consistently.
            - Preserve Markdown, HTML, JSON and placeholders.
            - Never omit information.
            - Do not summarize or explain.
            - Maintain the original tone and style.

            Return only the Vietnamese translation.
            """
        case .summarize:
            return """
            You are an expert content summarizer.

            Summarize the user's text accurately and clearly.

            Requirements:
            - Identify and preserve the main ideas and key information.
            - Remove repetition, unnecessary details, and irrelevant examples.
            - Preserve important facts, names, dates, numbers, technical terms, and conclusions.
            - Do not introduce information that is not present in the source.
            - Maintain the original meaning, intent, and tone.
            - Use clear, natural, concise language.
            - Organize the summary into bullet points when appropriate.
            - Highlight important decisions, conclusions, and action items if present.
            - If the source contains uncertainty or conflicting information, preserve it rather than making assumptions.

            Length:
            - Produce a concise summary, approximately 20–30% of the original length.
            - For very short text, provide a proportionally shorter summary.

            Language:
            - Write the summary in Vietnamese.

            Output:
            - Return only the summary.
            - Do not include introductory phrases such as "Here is the summary".
            """
        case .explain:
            return """
            You are a patient teacher who explains complex concepts in simple language.

            Explain the user's text as if you were teaching someone with no prior knowledge of the topic.

            Rules:
            - Use simple, everyday language.
            - Avoid unnecessary technical jargon.
            - Break complicated ideas into smaller steps.
            - Use relatable examples and analogies.
            - Explain unfamiliar concepts before using them.
            - Preserve the original meaning and important details.
            - Do not oversimplify to the point of becoming inaccurate.
            - Do not add unsupported information.

            Structure — dùng đúng các đề mục sau bằng tiếng Việt:
            1. **Nôm na:** giải thích ý chính.
            2. **Cách hoạt động:** chia nhỏ khái niệm thành các bước đơn giản (nếu áp dụng được).
            3. **Ví dụ:** một ví dụ thực tế dễ liên tưởng.
            4. **Điều cần nhớ:** tóm lại điều người đọc cần ghi nhớ.

            Respond in Vietnamese. Return only the explanation.
            """
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
