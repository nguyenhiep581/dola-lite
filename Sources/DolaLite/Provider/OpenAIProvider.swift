import Foundation

struct APIRequestBuilder {
    /// Relay chỉ chấp nhận User-Agent của các client lập trình được phép (Codex,
    /// Claude Code, …); User-Agent mặc định của URLSession bị chặn với
    /// `client_not_allowed` (HTTP 403). Giá trị này theo server đã kiểm chứng.
    static let allowedClientUserAgent = "codex_cli_rs/0.42.0"

    static func request(snapshot: APICredentialsSnapshot, skill: Skill, text: String) throws -> URLRequest {
        let configuration = try snapshot.configuration.validated()
        let key = snapshot.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APISettingsError.missingAPIKey }
        guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APISettingsError.invalidAPIKey
        }
        // "chat" = Chat Completions chuẩn OpenAI (NVIDIA NIM, api.openai.com…);
        // "responses" = Responses API (relay Xingchi chặn hẳn /chat/completions).
        let path = configuration.wireAPI == APIConfiguration.responsesWire ? "/responses" : "/chat/completions"
        guard let url = URL(string: configuration.baseURL + path) else {
            throw APISettingsError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.allowedClientUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let body: [String: Any]
        if configuration.wireAPI == APIConfiguration.responsesWire {
            body = [
                "model": configuration.model,
                "stream": true,
                "instructions": skill.systemPrompt,
                "input": text,
                "reasoning": ["effort": skill == .translate ? "low" : configuration.reasoningEffort]
            ]
        } else {
            // Không gửi reasoning_effort trên chat wire: nhiều nhà cung cấp
            // (NVIDIA NIM) từ chối tham số lạ — flash model vốn đã nhanh.
            body = [
                "model": configuration.model,
                "stream": true,
                "messages": [
                    ["role": "system", "content": skill.systemPrompt],
                    ["role": "user", "content": text]
                ]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

@MainActor
final class OpenAIProvider: AIProvider {
    private let configuration: @MainActor () throws -> APICredentialsSnapshot
    private let transport: any APITransport

    init(configuration: @escaping @MainActor () throws -> APICredentialsSnapshot,
         transport: (any APITransport)? = nil) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionStreamTransport()
    }

    /// Readiness is local and never sends text or credentials to the service.
    func ensureReady() async throws {
        do {
            _ = try APIRequestBuilder.request(snapshot: configuration(), skill: .translate, text: "")
        } catch {
            throw APIProviderError.safe(error)
        }
    }

    func stream(skill: Skill, text: String) -> AsyncThrowingStream<String, Error> {
        // Capture the settings at invocation time, so a queued task cannot pick up later edits.
        let request: Result<URLRequest, Error> = Result {
            try APIRequestBuilder.request(snapshot: configuration(), skill: skill, text: text)
        }
        let transport = self.transport
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let task = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    let response = try await transport.stream(for: request.get())
                    defer { response.cancel() }
                    try await withTaskCancellationHandler(operation: {
                        try Task.checkCancellation()
                        if let error = APIProviderError.status(response.response.statusCode) { throw error }
                        var decoder = APISSEDecoder()
                        for try await data in response.bytes {
                            try Task.checkCancellation()
                            for text in try decoder.append(data) {
                                if case .dropped = continuation.yield(text) { throw APIProviderError.responseTooLarge }
                            }
                            if decoder.isTerminal { break }
                        }
                        try decoder.finish()
                        try Task.checkCancellation()
                        continuation.finish()
                    }, onCancel: {
                        response.cancel()
                    })
                } catch {
                    continuation.finish(throwing: APIProviderError.safe(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
