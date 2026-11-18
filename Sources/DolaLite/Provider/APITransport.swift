import Foundation

struct APIStream: @unchecked Sendable {
    let response: HTTPURLResponse
    let bytes: AsyncThrowingStream<Data, Error>
    let cancel: @Sendable () -> Void
}

protocol APITransport: Sendable {
    func stream(for request: URLRequest) async throws -> APIStream
}

/// A URLSession delegate transport that exposes response body chunks as they arrive.
/// The delegate never logs request headers or body, and cancellation cancels the real task.
final class URLSessionStreamTransport: APITransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval

    init(configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 90) {
        self.configuration = configuration
        self.timeout = timeout
    }

    func stream(for request: URLRequest) async throws -> APIStream {
        var request = request
        request.timeoutInterval = timeout
        let state = StreamState()
        let bytes = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(64)) { continuation in
            state.bytesContinuation = continuation
            continuation.onTermination = { [weak state] _ in state?.cancel() }
        }
        let delegate = StreamDelegate(state: state)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        state.session = session
        let task = session.dataTask(with: request)
        state.task = task
        // Refuse redirects so authorization and selected text cannot be forwarded elsewhere.
        task.resume()

        do {
            let response = try await withTaskCancellationHandler(operation: {
                try await state.waitForResponse()
            }, onCancel: {
                state.cancel()
            })
            return APIStream(response: response, bytes: bytes) {
                state.cancel()
            }
        } catch {
            state.cancel()
            throw APIProviderError.safe(error)
        }
    }
}

private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    var task: URLSessionDataTask?
    var session: URLSession?
    var bytesContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var response: HTTPURLResponse?
    private var responseError: Error?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var cancelled = false

    func waitForResponse() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let response {
                lock.unlock()
                continuation.resume(returning: response)
            } else if let responseError {
                lock.unlock()
                continuation.resume(throwing: responseError)
            } else if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                responseContinuation = continuation
                lock.unlock()
            }
        }
    }

    func receive(_ response: HTTPURLResponse) {
        lock.lock()
        self.response = response
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }

    func complete(_ error: Error?) {
        lock.lock()
        let continuation = bytesContinuation
        bytesContinuation = nil
        let responseContinuation = self.responseContinuation
        self.responseContinuation = nil
        if response == nil { responseError = error ?? APIProviderError.invalidResponse }
        let response = self.response
        lock.unlock()
        if let error {
            continuation?.finish(throwing: error)
            responseContinuation?.resume(throwing: error)
        } else {
            continuation?.finish()
            if let response {
                responseContinuation?.resume(returning: response)
            } else {
                responseContinuation?.resume(throwing: APIProviderError.invalidResponse)
            }
        }
    }

    func yield(_ data: Data) {
        lock.lock()
        let continuation = bytesContinuation
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled else { return }
        // Bounded buffering fails explicitly instead of dropping stream bytes silently.
        if let result = continuation?.yield(data), case .dropped = result {
            complete(APIProviderError.responseTooLarge)
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let task = self.task
        let session = self.session
        let bytes = bytesContinuation
        bytesContinuation = nil
        let responseContinuation = self.responseContinuation
        self.responseContinuation = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        bytes?.finish(throwing: CancellationError())
        responseContinuation?.resume(throwing: CancellationError())
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    let state: StreamState

    init(state: StreamState) {
        self.state = state
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse {
            state.receive(response)
            // Status alone determines the safe user-facing error. Do not retain error bodies.
            completionHandler((200..<300).contains(response.statusCode) ? .allow : .cancel)
        } else {
            completionHandler(.cancel)
            state.complete(APIProviderError.invalidResponse)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        state.complete(error)
        session.finishTasksAndInvalidate()
    }
}
