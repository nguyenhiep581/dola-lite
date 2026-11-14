import Foundation

enum Skill: String, CaseIterable {
    case translate, summarize, explain

    var displayName: String {
        switch self {
        case .translate: return "Dịch"
        case .summarize: return "Tóm tắt"
        case .explain: return "Giải thích"
        }
    }

    /// Prompt template theo findings Phase 0, chat page của dola.com.
    func prompt(for text: String) -> String {
        switch self {
        case .translate:
            return "Translate the following text to Vietnamese. Reply with ONLY the translation:\n\n\(text)"
        case .summarize:
            return "Tóm tắt đoạn văn sau bằng tiếng Việt, ngắn gọn theo gạch đầu dòng:\n\n\(text)"
        case .explain:
            return "Giải thích đoạn văn sau bằng tiếng Việt, ngắn gọn dễ hiểu:\n\n\(text)"
        }
    }
}

protocol AIProvider {
    func ensureReady() async throws
    func stream(skill: Skill, text: String) -> AsyncThrowingStream<String, Error>
}

enum DolaError: LocalizedError {
    case notLoggedIn, pageNotReady, timeout, sendFailed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Chưa đăng nhập dola.com"
        case .pageNotReady: return "Trang chat chưa sẵn sàng"
        case .timeout: return "Hết thời gian chờ phản hồi"
        case .sendFailed: return "Không gửi được prompt vào trang chat"
        }
    }
}
