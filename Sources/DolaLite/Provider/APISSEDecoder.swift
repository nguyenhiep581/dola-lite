import Foundation

/// Incremental SSE framing over bytes: UTF-8 is decoded only after a complete line.
/// Accepts LF, CRLF and CR, comments, a leading BOM, and multiline data fields.
struct APISSEDecoder {
    static let maximumEventBytes = 1_048_576
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var previousWasCR = false
    private var firstLine = true
    private var eventType: String?
    private(set) var isTerminal = false
    private var hasVisibleContent = false

    mutating func append(_ data: Data) throws -> [String] {
        var output: [String] = []
        for byte in data {
            if isTerminal { break }
            if previousWasCR {
                previousWasCR = false
                if byte == 10 { continue }
            }
            if byte == 13 || byte == 10 {
                try consumeLine(into: &output)
                previousWasCR = byte == 13
            } else {
                guard line.count < Self.maximumEventBytes else { throw APIProviderError.responseTooLarge }
                line.append(byte)
            }
        }
        return output
    }

    mutating func finish() throws {
        guard isTerminal else {
            // An unterminated frame is never accepted as a successful completion.
            throw hasVisibleContent ? APIProviderError.incompleteResponse : APIProviderError.emptyResponse
        }
        guard hasVisibleContent else { throw APIProviderError.emptyResponse }
    }

    private mutating func consumeLine(into output: inout [String]) throws {
        guard var value = String(data: line, encoding: .utf8) else { throw APIProviderError.malformedStream }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        }
        if value.isEmpty {
            try consumeEvent(into: &output)
            return
        }
        if value.hasPrefix(":") { return }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var content = parts.count == 2 ? String(parts[1]) : ""
        if content.hasPrefix(" ") { content.removeFirst() }
        switch field {
        case "data":
            eventBytes += content.utf8.count + 1
            guard eventBytes <= Self.maximumEventBytes else { throw APIProviderError.responseTooLarge }
            dataLines.append(content)
        case "event": eventType = content
        default: break
        }
    }

    private mutating func consumeEvent(into output: inout [String]) throws {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            eventType = nil
        }
        if eventType == "error" { throw APIProviderError.serverError }
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            isTerminal = true
            return
        }
        guard let bytes = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw APIProviderError.malformedStream
        }
        if object["error"] != nil { throw APIProviderError.serverError }
        // Responses wire đánh dấu payload bằng "type"; chat wire dùng "choices".
        if let type = object["type"] as? String {
            try consumeResponsesEvent(type: type, object: object, into: &output)
        } else if object["choices"] != nil {
            try consumeChatEvent(object: object, into: &output)
        } else {
            throw APIProviderError.malformedStream
        }
    }

    /// OpenAI Responses API (relay Xingchi): text trong "delta" của từng event.
    private mutating func consumeResponsesEvent(type: String, object: [String: Any], into output: inout [String]) throws {
        switch type {
        case "response.output_text.delta":
            // Text chunks arrive one per event; other content types (reasoning,
            // audio, …) use different event names and are not surfaced.
            guard let delta = object["delta"] as? String else { throw APIProviderError.malformedStream }
            if !delta.isEmpty {
                hasVisibleContent = hasVisibleContent || !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                output.append(delta)
            }
        case "response.completed":
            isTerminal = true
        case "response.incomplete":
            let reason = ((object["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
            if reason == "max_output_tokens" { throw APIProviderError.truncatedResponse }
            isTerminal = true
        case "response.failed":
            throw APIProviderError.serverError
        default:
            // Lifecycle/structural events (created, queued, in_progress,
            // output_item.added, content_part.added, audio, …) carry no user text.
            break
        }
    }

    /// OpenAI Chat Completions (NVIDIA NIM, api.openai.com, …).
    private mutating func consumeChatEvent(object: [String: Any], into output: inout [String]) throws {
        guard let choices = object["choices"] as? [[String: Any]] else {
            throw APIProviderError.malformedStream
        }
        // Usage-only frames have an empty choices array. Other choices are
        // alternatives, not continuations; display only index zero.
        guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return }
        if let delta = choice["delta"] as? [String: Any] {
            if let content = delta["content"], !(content is NSNull) {
                guard let text = content as? String else { throw APIProviderError.malformedStream }
                if !text.isEmpty {
                    hasVisibleContent = hasVisibleContent || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    output.append(text)
                }
            }
        }
        if let reason = choice["finish_reason"], !(reason is NSNull) {
            guard let reason = reason as? String, !reason.isEmpty else { throw APIProviderError.malformedStream }
            if reason == "length" { throw APIProviderError.truncatedResponse }
            if reason == "error" { throw APIProviderError.serverError }
            isTerminal = true
        }
    }
}
