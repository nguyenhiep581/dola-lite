import Foundation
import Testing
@testable import DolaLite

@Suite struct APIRequestBuilderTests {
    private func configuration(wire: String) -> APIConfiguration {
        APIConfiguration(baseURL: "https://api.example.test/v1/",
                         model: "fixture-model",
                         reasoningEffort: "high",
                         wireAPI: wire)
    }

    @Test(arguments: [Skill.translate, .summarize, .explain])
    func buildsSafeStreamingResponsesRequest(for skill: Skill) throws {
        let request = try APIRequestBuilder.request(
            snapshot: APICredentialsSnapshot(configuration: configuration(wire: APIConfiguration.responsesWire), apiKey: "fixture-key"),
            skill: skill,
            text: "Xin chào 🌿\n世界"
        )
        #expect(request.url?.absoluteString == "https://api.example.test/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == APIRequestBuilder.allowedClientUserAgent)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "fixture-model")
        #expect(object["stream"] as? Bool == true)
        #expect(object["input"] as? String == "Xin chào 🌿\n世界")
        #expect((object["instructions"] as? String)?.contains(Self.roleKeyword(skill)) == true)
        let reasoning = try #require(object["reasoning"] as? [String: String])
        #expect(reasoning["effort"] == (skill == .translate ? "low" : "high"))
        #expect(object["messages"] == nil)
    }

    @Test(arguments: [Skill.translate, .summarize, .explain])
    func buildsSafeStreamingChatRequest(for skill: Skill) throws {
        let request = try APIRequestBuilder.request(
            snapshot: APICredentialsSnapshot(configuration: configuration(wire: APIConfiguration.chatWire), apiKey: "fixture-key"),
            skill: skill,
            text: "Xin chào 🌿\n世界"
        )
        #expect(request.url?.absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == APIRequestBuilder.allowedClientUserAgent)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "fixture-model")
        #expect(object["stream"] as? Bool == true)
        #expect(object["reasoning"] == nil)
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"]?.contains(Self.roleKeyword(skill)) == true)
        #expect(messages[1] == ["role": "user", "content": "Xin chào 🌿\n世界"])
    }

    private static func roleKeyword(_ skill: Skill) -> String {
        switch skill {
        case .translate: return "translator"
        case .summarize: return "summarizer"
        case .explain: return "teacher"
        }
    }

    @Test func rejectsUnsafeKeyWithoutPuttingItIntoTheRequest() {
        #expect(throws: APISettingsError.invalidAPIKey) {
            try APIRequestBuilder.request(
                snapshot: APICredentialsSnapshot(configuration: configuration(wire: APIConfiguration.chatWire), apiKey: "fixture\r\nInjected: value"),
                skill: .translate,
                text: "fixture"
            )
        }
    }

    @Test func buildsAuthenticatedModelsRequestFromConfiguredEndpoint() throws {
        let request = try APIRequestBuilder.modelsRequest(snapshot: APICredentialsSnapshot(
            configuration: configuration(wire: APIConfiguration.responsesWire), apiKey: "fixture-key"
        ))
        #expect(request.url?.absoluteString == "https://api.example.test/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpBody == nil)
    }

    @Test func buildsModelsRequestWhenModelFieldIsEmpty() throws {
        let emptyModelConfig = APIConfiguration(baseURL: "https://api.example.test/v1/",
                                                model: "   ",
                                                reasoningEffort: "high",
                                                wireAPI: APIConfiguration.chatWire)
        let request = try APIRequestBuilder.modelsRequest(snapshot: APICredentialsSnapshot(
            configuration: emptyModelConfig, apiKey: "fixture-key"
        ))
        #expect(request.url?.absoluteString == "https://api.example.test/v1/models")
    }
}

@Suite struct APIModelCatalogTests {
    @Test @MainActor
    func fetchesDeduplicatedSortedModelIdentifiers() async throws {
        let transport = FixtureAPITransport(status: 200, body: Data(#"{"data":[{"id":"model-z"},{"id":"model-a"},{"id":"model-z"},{"name":"without-id"},{"id":"  "}]}"#.utf8))
        let models = try await APIModelCatalog.fetch(snapshot: fixtureSnapshot, transport: transport)
        #expect(models == ["model-a", "model-z"])
        #expect(await transport.requestCount == 1)
    }

    @Test @MainActor
    func rejectsMalformedModelList() async {
        let transport = FixtureAPITransport(status: 200, body: Data(#"{"models":[{"id":"fixture"}]}"#.utf8))
        do {
            _ = try await APIModelCatalog.fetch(snapshot: fixtureSnapshot, transport: transport)
            Issue.record("Expected an invalid response")
        } catch {
            #expect(error as? APIProviderError == .invalidResponse)
        }
    }

    @Test @MainActor
    func mapsModelListHTTPStatus() async {
        let transport = FixtureAPITransport(status: 401, body: Data("private response body".utf8))
        do {
            _ = try await APIModelCatalog.fetch(snapshot: fixtureSnapshot, transport: transport)
            Issue.record("Expected an unauthorized response")
        } catch {
            #expect(error as? APIProviderError == .unauthorized)
            #expect(error.localizedDescription.contains("private response body") == false)
        }
    }

    @Test @MainActor
    func sanitizesTransportNetworkErrorsDuringModelFetch() async {
        let transport = ThrowingAPITransport(error: URLError(.notConnectedToInternet))
        do {
            _ = try await APIModelCatalog.fetch(snapshot: fixtureSnapshot, transport: transport)
            Issue.record("Expected a safe network error")
        } catch {
            #expect(error as? APIProviderError == .network)
        }
    }
}

private final class ThrowingAPITransport: APITransport, @unchecked Sendable {
    let error: Error
    init(error: Error) { self.error = error }
    func stream(for request: URLRequest) async throws -> APIStream {
        throw error
    }
}

@Suite struct APISSEDecoderTests {
    @Test func decodesAcrossArbitraryUTF8AndCRLFBorders() throws {
        let wire = Data([
            239, 187, 191
        ] + Array("event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Xin chào 🇻🇳\"".utf8)
          + Array("}\r\n\r\n: keepalive\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"!\"}\r\n\r\nevent: response.completed\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n".utf8))
        var decoder = APISSEDecoder()
        var output: [String] = []
        for byte in wire {
            output += try decoder.append(Data([byte]))
        }
        try decoder.finish()
        #expect(output.joined() == "Xin chào 🇻🇳!")
        #expect(decoder.isTerminal)
    }

    @Test func joinsMultilineDataAndAcceptsDoneSentinel() throws {
        var decoder = APISSEDecoder()
        let chunk = Data("data: {\"type\":\"response.output_text.delta\",\ndata: \"delta\":\"ok\"}\n\ndata: [DONE]\n\n".utf8)
        let output = try decoder.append(chunk)
        try decoder.finish()
        #expect(output == ["ok"])
    }

    @Test func ignoresLifecycleEventsAndRejectsTruncation() throws {
        var decoder = APISSEDecoder()
        let lifecycle = Data("event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"status\":\"queued\"}}\n\n".utf8)
        #expect(try decoder.append(lifecycle).isEmpty)
        let reasoning = Data("data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"secret\"}\n\n".utf8)
        #expect(try decoder.append(reasoning).isEmpty)
        #expect(throws: APIProviderError.truncatedResponse) {
            _ = try decoder.append(Data("event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n".utf8))
        }
    }

    @Test func malformedEventFails() {
        var decoder = APISSEDecoder()
        #expect(throws: APIProviderError.malformedStream) {
            _ = try decoder.append(Data("data: {not-json}\n\n".utf8))
        }
    }

    @Test func errorEventDoesNotExposeServerText() {
        var decoder = APISSEDecoder()
        do {
            _ = try decoder.append(Data("event: error\ndata: private server details\n\n".utf8))
            Issue.record("Expected a sanitized server error")
        } catch {
            #expect(error as? APIProviderError == .serverError)
            #expect(error.localizedDescription.contains("private server details") == false)
        }
    }

    @Test func eofBeforeTerminalFails() throws {
        var decoder = APISSEDecoder()
        _ = try decoder.append(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8))
        #expect(throws: APIProviderError.incompleteResponse) { try decoder.finish() }
    }

    // MARK: - Chat Completions wire (NVIDIA NIM, api.openai.com, …)

    @Test func decodesChatDeltasAndFinishReason() throws {
        var decoder = APISSEDecoder()
        let wire = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Xin \"}}]}\n\n".utf8)
            + Data(": keepalive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"chào\"}}]}\n\n".utf8)
            + Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8)
        let output = try decoder.append(wire)
        try decoder.finish()
        #expect(output == ["Xin ", "chào"])
        #expect(decoder.isTerminal)
    }

    @Test func chatUsageOnlyFramesIgnoredAndTruncationRejected() throws {
        var decoder = APISSEDecoder()
        #expect(try decoder.append(Data("data: {\"choices\":[],\"usage\":{\"total_tokens\":7}}\n\n".utf8)).isEmpty)
        #expect(try decoder.append(Data("data: {\"choices\":[{\"delta\":{\"reasoning\":\"secret\"}}]}\n\n".utf8)).isEmpty)
        #expect(throws: APIProviderError.truncatedResponse) {
            _ = try decoder.append(Data("data: {\"choices\":[{\"finish_reason\":\"length\"}]}\n\n".utf8))
        }
    }
}

@Suite struct APIProviderStreamTests {
    @Test(arguments: [401, 403, 429, 503, 418])
    @MainActor
    func mapsHTTPStatus(_ status: Int) async throws {
        let transport = FixtureAPITransport(status: status, body: Data("private response body".utf8))
        let provider = OpenAIProvider(configuration: { fixtureSnapshot }, transport: transport)
        var receivedError: Error?
        do {
            for try await _ in provider.stream(skill: .translate, text: "fixture") {}
        } catch {
            receivedError = error
        }
        #expect(receivedError as? APIProviderError == APIProviderError.status(status))
        #expect(receivedError?.localizedDescription.contains("private response body") == false)
    }

    @Test @MainActor
    func streamsOnlyContentAndReleasesTransportAfterCompletion() async throws {
        let cleanedUp = CancellationFlag()
        let bytes = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"hidden\"}\n\n".utf8))
            continuation.yield(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"visible\"}\n\n".utf8))
            continuation.yield(Data("event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n".utf8))
            continuation.finish()
        }
        let transport = FixtureAPITransport(status: 200, bytes: bytes, onCancel: { cleanedUp.set() })
        let provider = OpenAIProvider(configuration: { fixtureSnapshot }, transport: transport)
        var output = ""
        for try await chunk in provider.stream(skill: .explain, text: "fixture") { output += chunk }
        #expect(output == "visible")
        #expect(cleanedUp.value)
    }

    @Test @MainActor
    func cancellingConsumerCancelsOpenTransport() async {
        let cancelled = CancellationFlag()
        let openBytes = AsyncThrowingStream<Data, Error> { _ in }
        let transport = FixtureAPITransport(status: 200, bytes: openBytes, onCancel: { cancelled.set() })
        let provider = OpenAIProvider(configuration: { fixtureSnapshot }, transport: transport)
        let response = provider.stream(skill: .translate, text: "fixture")
        let consumer = Task {
            do {
                for try await _ in response {}
            } catch {}
        }
        await transport.waitForRequest()
        consumer.cancel()
        for _ in 0..<100 where !cancelled.value { await Task.yield() }
        #expect(cancelled.value)
    }

    @Test @MainActor
    func ensureReadyUsesLocalSnapshotOnly() async throws {
        let transport = FixtureAPITransport(status: 200, body: Data())
        let provider = OpenAIProvider(configuration: { fixtureSnapshot }, transport: transport)
        try await provider.ensureReady()
        let requestCount = await transport.requestCount
        #expect(requestCount == 0)
    }
}

private let fixtureSnapshot = APICredentialsSnapshot(
    configuration: APIConfiguration(baseURL: "https://api.example.test/v1", model: "fixture", reasoningEffort: "medium"),
    apiKey: "fixture-key"
)

private actor FixtureAPITransport: APITransport {
    private let responseStatus: Int
    private let bytes: AsyncThrowingStream<Data, Error>
    private let onCancel: @Sendable () -> Void
    private(set) var requestCount = 0
    private var requestWaiter: CheckedContinuation<Void, Never>?

    func waitForRequest() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    init(status: Int, body: Data) {
        responseStatus = status
        bytes = AsyncThrowingStream { continuation in continuation.yield(body); continuation.finish() }
        onCancel = {}
    }

    init(status: Int, bytes: AsyncThrowingStream<Data, Error>, onCancel: @escaping @Sendable () -> Void) {
        responseStatus = status
        self.bytes = bytes
        self.onCancel = onCancel
    }

    func stream(for request: URLRequest) async throws -> APIStream {
        requestCount += 1
        requestWaiter?.resume()
        requestWaiter = nil
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: responseStatus,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw APIProviderError.invalidResponse
        }
        return APIStream(response: response, bytes: bytes, cancel: onCancel)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}
