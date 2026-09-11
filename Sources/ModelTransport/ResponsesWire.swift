import Foundation

public enum OpenAIAPI: String, Codable, CaseIterable, Sendable {
    case auto
    case responses
    case chatCompletions = "chat-completions"
}

/// The text conversation subset of OpenAI's Responses request format.
public struct ResponsesRequest: Codable, Equatable, Sendable {
    public struct Reasoning: Codable, Equatable, Sendable {
        public let effort: ReasoningEffort

        public init(effort: ReasoningEffort) { self.effort = effort }
    }

    public let model: String
    public let input: [OpenAIMessage]
    public let stream: Bool
    public let store: Bool
    public let previousResponseID: String?
    public let maxOutputTokens: Int?
    public let temperature: Double?
    public let reasoning: Reasoning?

    public init(
        model: String,
        input: [OpenAIMessage],
        stream: Bool = true,
        store: Bool = true,
        previousResponseID: String? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.model = model
        self.input = input
        self.stream = stream
        self.store = store
        self.previousResponseID = previousResponseID
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.reasoning = reasoningEffort.map(Reasoning.init(effort:))
    }

    enum CodingKeys: String, CodingKey {
        case model, input, stream, store, temperature, reasoning
        case previousResponseID = "previous_response_id"
        case maxOutputTokens = "max_output_tokens"
    }
}
