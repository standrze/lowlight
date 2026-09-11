import Foundation
import ModelTransport

/// Reconciles semantic deltas with the authoritative terminal Responses object.
/// Only text and reasoning are supported: Lowlight does not execute tools.
struct ResponsesStreamState {
    private(set) var reasoningChunks: [String] = []
    private(set) var answer = ""
    private(set) var reachedTerminalEvent = false
    private(set) var finishReason: String?
    private(set) var usage: OpenAIUsage?
    private(set) var performance: ModelRunnerPerformance?
    private(set) var responseID: String?

    private struct Coordinate: Hashable, Comparable {
        let output: Int
        let content: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.output == rhs.output ? lhs.content < rhs.content : lhs.output < rhs.output
        }
    }

    private var textParts: [Coordinate: String] = [:]
    private var partKinds: [Coordinate: String] = [:]
    private var lastTextCoordinate: Coordinate?
    private var reasoningParts: [String: String] = [:]

    mutating func consume(_ dataString: String) throws -> [String] {
        reasoningChunks = []
        // Responses has a semantic terminal event. A sentinel cannot replace it.
        if dataString == "[DONE]" { return [] }
        guard !reachedTerminalEvent else { throw EndpointSessionError.invalidResponse }
        let data = Data(dataString.utf8)
        if let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
            throw EndpointSessionError.server(envelope.error.message)
        }
        let event = try JSONDecoder().decode(Event.self, from: data)
        if let metadata = event.modelRunner?.performance { performance = metadata }
        let coordinate = Coordinate(output: event.outputIndex ?? 0, content: event.contentIndex ?? 0)
        guard coordinate.output >= 0, coordinate.content >= 0 else {
            throw EndpointSessionError.invalidResponse
        }

        switch event.type {
        case "response.created", "response.in_progress", "response.queued":
            if let response = event.response { try captureMetadata(response) }
            return []
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event.delta else { throw EndpointSessionError.invalidResponse }
            return try append(delta, at: coordinate, kind: event.type == "response.refusal.delta" ? "refusal" : "output_text")
        case "response.output_text.done", "response.refusal.done":
            let kind = event.type == "response.refusal.done" ? "refusal" : "output_text"
            guard let value = kind == "refusal" ? event.refusal : event.text else {
                throw EndpointSessionError.invalidResponse
            }
            return try reconcile(value, at: coordinate, kind: kind)
        case "response.content_part.added", "response.content_part.done":
            guard let part = event.part else { throw EndpointSessionError.invalidResponse }
            return try reconcile(part, at: coordinate)
        case "response.output_item.added", "response.output_item.done":
            guard let item = event.item else { throw EndpointSessionError.invalidResponse }
            return try reconcile(item, outputIndex: coordinate.output)
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            guard let delta = event.delta else { throw EndpointSessionError.invalidResponse }
            let key = reasoningKey(event)
            reasoningParts[key, default: ""] += delta
            if !delta.isEmpty { reasoningChunks.append(delta) }
            return []
        case "response.reasoning_text.done", "response.reasoning_summary_text.done":
            guard let text = event.text else { throw EndpointSessionError.invalidResponse }
            try reconcileReasoning(text, key: reasoningKey(event))
            return []
        case "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
            guard let part = event.part, part.type == "summary_text", let text = part.text else {
                throw EndpointSessionError.invalidResponse
            }
            try reconcileReasoning(text, key: reasoningKey(event))
            return []
        case "response.completed", "response.incomplete":
            guard let response = event.response,
                  response.status == String(event.type.dropFirst("response.".count)),
                  let output = response.output,
                  let id = response.id, !id.isEmpty
            else { throw EndpointSessionError.invalidResponse }
            try captureMetadata(response)
            if let error = response.error { throw EndpointSessionError.server(error.message) }
            var chunks: [String] = []
            var finalText = ""
            for (outputIndex, item) in output.enumerated() {
                chunks += try reconcile(item, outputIndex: outputIndex)
                if item.type == "message" {
                    for part in item.content ?? [] {
                        finalText += try text(from: part)
                    }
                }
            }
            // Never silently save text that disagrees with what was shown while streaming.
            guard finalText.utf8.elementsEqual(answer.utf8) else { throw EndpointSessionError.invalidResponse }
            if response.status == "completed" {
                finishReason = "stop"
            } else {
                switch response.incompleteDetails?.reason {
                case "max_output_tokens": finishReason = "length"
                case "content_filter": finishReason = "content_filter"
                case .some(let reason):
                    throw EndpointSessionError.server("The response is incomplete: \(reason).")
                case .none: throw EndpointSessionError.invalidResponse
                }
            }
            reachedTerminalEvent = true
            return chunks
        case "response.failed", "response.cancelled":
            if let response = event.response {
                try captureMetadata(response)
                if let error = response.error { throw EndpointSessionError.server(error.message) }
            }
            throw EndpointSessionError.server(event.type == "response.cancelled" ? "The server cancelled the response." : "The server failed to generate a response.")
        case "error":
            throw EndpointSessionError.server(event.message ?? "The endpoint reported a streaming error.")
        case "response.output_text.annotation.added":
            return []
        default:
            // Unknown output modalities and tool streams must never look like successful chat.
            throw EndpointSessionError.server("Lowlight does not support the Responses event '\(event.type)'.")
        }
    }

    func validateTerminalEvent() throws {
        guard reachedTerminalEvent else { throw EndpointSessionError.incompleteStream }
    }

    func validateCompletion() throws {
        try validateTerminalEvent()
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if finishReason == "length" { throw EndpointSessionError.outputLimitReached }
            throw EndpointSessionError.emptyResponse
        }
    }

    private mutating func captureMetadata(_ response: Response) throws {
        if let id = response.id {
            if let responseID, responseID != id { throw EndpointSessionError.invalidResponse }
            responseID = id
        }
        if let value = response.usage {
            guard value.inputTokens >= 0, value.outputTokens >= 0, value.totalTokens >= 0 else {
                throw EndpointSessionError.invalidResponse
            }
            usage = .init(promptTokens: value.inputTokens, completionTokens: value.outputTokens, totalTokens: value.totalTokens, cachedTokens: value.inputTokensDetails?.cachedTokens)
        }
        if let value = response.modelRunner?.performance { performance = value }
    }

    private mutating func append(_ value: String, at coordinate: Coordinate, kind: String) throws -> [String] {
        if let previousKind = partKinds[coordinate], previousKind != kind {
            throw EndpointSessionError.invalidResponse
        }
        partKinds[coordinate] = kind
        guard !value.isEmpty else { return [] }
        if let lastTextCoordinate, coordinate < lastTextCoordinate {
            throw EndpointSessionError.invalidResponse
        }
        lastTextCoordinate = coordinate
        textParts[coordinate, default: ""] += value
        answer += value
        return [value]
    }

    private mutating func reconcile(_ value: String, at coordinate: Coordinate, kind: String) throws -> [String] {
        let previous = textParts[coordinate] ?? ""
        guard value.utf8.starts(with: previous.utf8) else { throw EndpointSessionError.invalidResponse }
        return try append(String(decoding: value.utf8.dropFirst(previous.utf8.count), as: UTF8.self), at: coordinate, kind: kind)
    }

    private mutating func reconcile(_ part: Part, at coordinate: Coordinate) throws -> [String] {
        try reconcile(text(from: part), at: coordinate, kind: part.type)
    }

    private mutating func reconcile(_ item: Item, outputIndex: Int) throws -> [String] {
        switch item.type {
        case "message":
            guard item.role == "assistant", let content = item.content else {
                throw EndpointSessionError.invalidResponse
            }
            var chunks: [String] = []
            for (contentIndex, part) in content.enumerated() {
                chunks += try reconcile(part, at: .init(output: outputIndex, content: contentIndex))
            }
            return chunks
        case "reasoning":
            for (index, part) in (item.summary ?? []).enumerated() {
                guard part.type == "summary_text", let text = part.text else {
                    throw EndpointSessionError.invalidResponse
                }
                try reconcileReasoning(text, key: "summary:\(outputIndex):\(index)")
            }
            for (index, part) in (item.content ?? []).enumerated() {
                guard part.type == "reasoning_text", let text = part.text else {
                    throw EndpointSessionError.invalidResponse
                }
                try reconcileReasoning(text, key: "text:\(outputIndex):\(index)")
            }
            return []
        default:
            throw EndpointSessionError.server("Lowlight supports text conversations; the endpoint returned unsupported '\(item.type)' output.")
        }
    }

    private func text(from part: Part) throws -> String {
        switch part.type {
        case "output_text":
            guard let text = part.text else { throw EndpointSessionError.invalidResponse }
            return text
        case "refusal":
            guard let refusal = part.refusal else { throw EndpointSessionError.invalidResponse }
            return refusal
        default:
            throw EndpointSessionError.server("Lowlight does not support Responses content '\(part.type)'.")
        }
    }

    private func reasoningKey(_ event: Event) -> String {
        let isSummary = event.type.contains("summary")
        return "\(isSummary ? "summary" : "text"):\(event.outputIndex ?? 0):\(isSummary ? event.summaryIndex ?? 0 : event.contentIndex ?? 0)"
    }

    private mutating func reconcileReasoning(_ text: String, key: String) throws {
        let previous = reasoningParts[key] ?? ""
        guard text.utf8.starts(with: previous.utf8) else { throw EndpointSessionError.invalidResponse }
        let remainder = String(decoding: text.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
        reasoningParts[key] = text
        if !remainder.isEmpty { reasoningChunks.append(remainder) }
    }

    private struct Event: Decodable {
        let type: String
        let delta: String?
        let text: String?
        let refusal: String?
        let message: String?
        let outputIndex: Int?
        let contentIndex: Int?
        let summaryIndex: Int?
        let response: Response?
        let item: Item?
        let part: Part?
        let modelRunner: ModelRunnerMetadata?

        enum CodingKeys: String, CodingKey {
            case type, delta, text, refusal, message, response, item, part
            case outputIndex = "output_index"
            case contentIndex = "content_index"
            case summaryIndex = "summary_index"
            case modelRunner = "model_runner"
        }
    }

    private struct Response: Decodable {
        struct IncompleteDetails: Decodable { let reason: String }
        struct Failure: Decodable { let message: String }
        struct Usage: Decodable {
            struct InputTokensDetails: Decodable {
                let cachedTokens: Int?
                enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
            }
            let inputTokensDetails: InputTokensDetails?

            let inputTokens: Int
            let outputTokens: Int
            let totalTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokensDetails = "input_tokens_details"
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case totalTokens = "total_tokens"
            }
        }
        let id: String?
        let status: String?
        let output: [Item]?
        let error: Failure?
        let incompleteDetails: IncompleteDetails?
        let usage: Usage?
        let modelRunner: ModelRunnerMetadata?

        enum CodingKeys: String, CodingKey {
            case id, status, output, error, usage
            case incompleteDetails = "incomplete_details"
            case modelRunner = "model_runner"
        }
    }

    private struct Item: Decodable {
        let type: String
        let role: String?
        let content: [Part]?
        let summary: [Part]?
    }

    private struct Part: Decodable {
        let type: String
        let text: String?
        let refusal: String?
    }
}
