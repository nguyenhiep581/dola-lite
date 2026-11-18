import Foundation
import Testing
@testable import DolaLite

@Suite struct URLSessionTransportTests {
    @Test @MainActor
    func streamsAllThreeSkillsThroughURLSession() async throws {
        let provider = OpenAIProvider(configuration: {
            APICredentialsSnapshot(
                configuration: APIConfiguration(baseURL: "https://transport-fixture.invalid/v1"),
                apiKey: "test-key"
            )
        }, transport: makeTransport())

        for skill in Skill.allCases {
            var chunks: [String] = []
            for try await chunk in provider.stream(skill: skill, text: "Fixture input") {
                chunks.append(chunk)
            }
            #expect(chunks == ["Xin ", "chào"])
        }
    }

    @Test @MainActor
    func cancellingConsumerStopsURLSessionLoad() async throws {
        let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        FixtureURLProtocol.setStopHandler { stopped.continuation.yield(()); stopped.continuation.finish() }
        defer { FixtureURLProtocol.setStopHandler(nil) }

        let provider = OpenAIProvider(configuration: {
            APICredentialsSnapshot(
                configuration: APIConfiguration(baseURL: "https://transport-fixture.invalid/cancel"),
                apiKey: "test-key"
            )
        }, transport: makeTransport())
        let stream = provider.stream(skill: .translate, text: "Fixture input")
        var iterator = stream.makeAsyncIterator()
        let firstChunk = try await iterator.next()
        #expect(firstChunk == "Xin ")

        let consumer = Task { try await iterator.next() }
        consumer.cancel()
        _ = try? await consumer.value

        // Bound the wait so a regression produces a test failure instead of a hang.
        let deadline = Task {
            try await Task.sleep(for: .seconds(2))
            stopped.continuation.finish()
        }
        defer { deadline.cancel() }
        var stopEvents = stopped.stream.makeAsyncIterator()
        let didStop = await stopEvents.next() != nil
        #expect(didStop)
    }

    private func makeTransport() -> URLSessionStreamTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSessionStreamTransport(configuration: configuration, timeout: 5)
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var stopHandler: (@Sendable () -> Void)?

    static func setStopHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { stopHandler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "transport-fixture.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Xin \"}\n\n".utf8))
        if url.path.hasPrefix("/cancel/") { return }
        client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"chào\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\"}\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard request.url?.path.hasPrefix("/cancel/") == true else { return }
        let handler = Self.lock.withLock { Self.stopHandler }
        handler?()
    }
}
