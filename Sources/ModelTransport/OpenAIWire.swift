import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

public struct OpenAIMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String?

    public init(role: String, content: String?) {
        self.role = role
        self.content = content
    }
}

public struct ChatCompletionRequest: Codable, Equatable, Sendable {
    public struct StreamOptions: Codable, Equatable, Sendable {
        public let includeUsage: Bool

        public init(includeUsage: Bool) {
            self.includeUsage = includeUsage
        }

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    public let model: String
    public let messages: [OpenAIMessage]
    public let stream: Bool
    public let maxTokens: Int?
    public let temperature: Double?
    public let streamOptions: StreamOptions?
    public let reasoningEffort: ReasoningEffort?

    public init(
        model: String,
        messages: [OpenAIMessage],
        stream: Bool = true,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        streamOptions: StreamOptions? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.streamOptions = streamOptions
        self.reasoningEffort = reasoningEffort
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
    }
}

public struct OpenAIUsage: Codable, Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct ModelRunnerPerformance: Codable, Equatable, Sendable {
    public let promptTokensPerSecond: Double?
    public let tokensPerSecond: Double?

    public init(promptTokensPerSecond: Double? = nil, tokensPerSecond: Double? = nil) {
        self.promptTokensPerSecond = promptTokensPerSecond
        self.tokensPerSecond = tokensPerSecond
    }

    enum CodingKeys: String, CodingKey {
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case tokensPerSecond = "tokens_per_second"
    }
}

public struct ModelRunnerMetadata: Codable, Equatable, Sendable {
    public let performance: ModelRunnerPerformance?

    public init(performance: ModelRunnerPerformance? = nil) {
        self.performance = performance
    }
}

public struct ChatCompletionChunk: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public struct Delta: Codable, Equatable, Sendable {
            public let role: String?
            public let content: String?
            public let reasoningContent: String?
            public let reasoning: String?

            public init(role: String? = nil, content: String? = nil, reasoningContent: String? = nil, reasoning: String? = nil) {
                self.role = role
                self.content = content
                self.reasoningContent = reasoningContent
                self.reasoning = reasoning
            }

            enum CodingKeys: String, CodingKey {
                case role, content, reasoning
                case reasoningContent = "reasoning_content"
            }
        }

        public let index: Int
        public let delta: Delta
        public let finishReason: String?

        public init(index: Int = 0, delta: Delta, finishReason: String? = nil) {
            self.index = index
            self.delta = delta
            self.finishReason = finishReason
        }

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [Choice]
    public let usage: OpenAIUsage?
    public let modelRunner: ModelRunnerMetadata?

    public init(
        id: String,
        model: String,
        choices: [Choice],
        usage: OpenAIUsage? = nil,
        modelRunner: ModelRunnerMetadata? = nil
    ) {
        self.id = id
        self.object = "chat.completion.chunk"
        self.created = Int(Date().timeIntervalSince1970)
        self.model = model
        self.choices = choices
        self.usage = usage
        self.modelRunner = modelRunner
    }

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case modelRunner = "model_runner"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        object = try container.decodeIfPresent(String.self, forKey: .object)
            ?? "chat.completion.chunk"
        created = try container.decodeIfPresent(Int.self, forKey: .created) ?? 0
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(OpenAIUsage.self, forKey: .usage)
        modelRunner = try container.decodeIfPresent(ModelRunnerMetadata.self, forKey: .modelRunner)
    }
}

public struct OpenAIErrorEnvelope: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public let message: String
        public let type: String

        public init(message: String, type: String = "server_error") {
            self.message = message
            self.type = type
        }
    }

    public let error: Detail

    public init(message: String) {
        self.error = Detail(message: message)
    }
}

public struct OpenAIModel: Codable, Equatable, Sendable {
    public let id: String
    public let contextWindow: Int?
    public let supportedReasoningEfforts: [String]?

    public init(id: String, contextWindow: Int? = nil, supportedReasoningEfforts: [String]? = nil) {
        self.id = id
        self.contextWindow = contextWindow
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }

    enum CodingKeys: String, CodingKey {
        case id
        case contextWindow = "context_window"
        case contextLength = "context_length"
        case maxModelLength = "max_model_len"
        case supportedReasoningEfforts = "supported_reasoning_efforts"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let context = (try? values.decode(Int.self, forKey: .contextWindow))
            ?? (try? values.decode(Int.self, forKey: .contextLength))
            ?? (try? values.decode(Int.self, forKey: .maxModelLength))
        contextWindow = context.flatMap { $0 > 0 ? $0 : nil }
        supportedReasoningEfforts = try? values.decode([String].self, forKey: .supportedReasoningEfforts)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try values.encodeIfPresent(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
    }

    public func settingIssues(contextWindow requested: Int, effort: ReasoningEffort?) -> [String] {
        var issues: [String] = []
        if let contextWindow, requested > contextWindow {
            issues.append("Configured context \(requested) exceeds the server-reported limit \(contextWindow). Use /set context-window \(contextWindow).")
        }
        if let effort, let supportedReasoningEfforts, !supportedReasoningEfforts.contains(effort.rawValue) {
            issues.append("The server does not advertise '\(effort.rawValue)' effort for this model. Use /effort default.")
        }
        return issues
    }
}

public struct OpenAIModelsResponse: Codable, Equatable, Sendable {
    public let data: [OpenAIModel]

    public init(data: [OpenAIModel]) {
        self.data = data
    }
}

public struct OpenAISpeechRequest: Codable, Equatable, Sendable {
    public let model: String
    public let voice: String
    public let input: String
    public let responseFormat: String

    public init(model: String, voice: String, input: String, responseFormat: String) {
        self.model = model
        self.voice = voice
        self.input = input
        self.responseFormat = responseFormat
    }

    enum CodingKeys: String, CodingKey {
        case model, voice, input
        case responseFormat = "response_format"
    }
}

public enum OpenAIEndpoint {
    public static func chatCompletionsURL(from base: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil
        else {
            throw OpenAIEndpointError.invalidURL(base)
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            // The caller supplied the complete endpoint.
        } else if path.hasSuffix("v1") {
            components.path = "/\(path)/chat/completions"
        } else if path.isEmpty {
            components.path = "/v1/chat/completions"
        } else {
            components.path = "/\(path)/v1/chat/completions"
        }

        guard let url = components.url else {
            throw OpenAIEndpointError.invalidURL(base)
        }
        return url
    }

    public static func modelsURL(from base: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil
        else {
            throw OpenAIEndpointError.invalidURL(base)
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            path.removeLast("chat/completions".count)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if path.hasSuffix("v1") {
            components.path = "/\(path)/models"
        } else if path.isEmpty {
            components.path = "/v1/models"
        } else {
            components.path = "/\(path)/v1/models"
        }

        guard let url = components.url else {
            throw OpenAIEndpointError.invalidURL(base)
        }
        return url
    }

    public static func speechURL(from base: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil
        else {
            throw OpenAIEndpointError.invalidURL(base)
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["chat/completions", "audio/speech", "models"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            break
        }
        if path.hasSuffix("v1") {
            components.path = "/\(path)/audio/speech"
        } else if path.isEmpty {
            components.path = "/v1/audio/speech"
        } else {
            components.path = "/\(path)/v1/audio/speech"
        }

        guard let url = components.url else {
            throw OpenAIEndpointError.invalidURL(base)
        }
        return url
    }
}

public enum OpenAIEndpointError: LocalizedError, Equatable {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value): "Invalid endpoint URL: \(value)"
        }
    }
}
