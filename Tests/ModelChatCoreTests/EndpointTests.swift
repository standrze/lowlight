import Foundation
import ModelTransport
import Testing
@testable import ModelChatCore

@Test
func endpointBaseURLsResolveToChatCompletions() throws {
    #expect(
        try OpenAIEndpoint.chatCompletionsURL(from: "http://localhost:11434/v1").absoluteString
            == "http://localhost:11434/v1/chat/completions"
    )
    #expect(
        try OpenAIEndpoint.chatCompletionsURL(
            from: "http://127.0.0.1:8000/v1/chat/completions"
        ).absoluteString == "http://127.0.0.1:8000/v1/chat/completions"
    )
}

@Test
func endpointBaseURLsResolveToModels() throws {
    #expect(
        try OpenAIEndpoint.modelsURL(from: "http://localhost:11434/v1").absoluteString
            == "http://localhost:11434/v1/models"
    )
    #expect(
        try OpenAIEndpoint.modelsURL(
            from: "http://localhost:11434/v1/chat/completions"
        ).absoluteString == "http://localhost:11434/v1/models"
    )
}

@Test
func endpointBaseURLsResolveToSpeech() throws {
    #expect(
        try OpenAIEndpoint.speechURL(from: "http://localhost:11434/v1").absoluteString
            == "http://localhost:11434/v1/audio/speech"
    )
}

@Test
func speechRequestUsesOpenAICompatibleFieldNames() throws {
    let data = try JSONEncoder().encode(
        OpenAISpeechRequest(model: "tts-1", voice: "alloy", input: "Hello", responseFormat: "mp3")
    )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["response_format"] as? String == "mp3")
    #expect(object["input"] as? String == "Hello")
}

@Test
func chatRequestUsesOpenAICompatibleFieldNames() throws {
    let request = ChatCompletionRequest(
        model: "gemma",
        messages: [.init(role: "user", content: "hello")],
        maxTokens: 64,
        temperature: 0
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )

    #expect(object["model"] as? String == "gemma")
    #expect(object["stream"] as? Bool == true)
    #expect(object["max_tokens"] as? Int == 64)
}

@Test
func streamingRequestAsksForUsage() throws {
    let request = ChatCompletionRequest(
        model: "gemma",
        messages: [.init(role: "user", content: "hello")],
        streamOptions: .init(includeUsage: true)
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )
    let streamOptions = try #require(object["stream_options"] as? [String: Any])

    #expect(streamOptions["include_usage"] as? Bool == true)
}

@Test
func serverSentEventLinesAreParsedWithoutPrefixWhitespace() {
    #expect(EndpointModelSession.sseData(from: "data: {\"ok\":true}") == "{\"ok\":true}")
    #expect(EndpointModelSession.sseData(from: "data: [DONE]") == "[DONE]")
    #expect(EndpointModelSession.sseData(from: ": keep-alive") == nil)
}

@Test
func serverSentEventCompletionAcceptsCRLF() throws {
    var buffer = SSELineBuffer()
    var stream = OpenAIStreamState()
    let events = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
    for line in buffer.append(Data(events.utf8)) {
        guard let data = EndpointModelSession.sseData(from: line) else { continue }
        _ = try stream.consume(data)
    }
    try stream.validateCompletion()
    #expect(stream.answer == "Hello")
    #expect(stream.reachedTerminalEvent)
}

@Test
func runnerEmptyGenerationErrorPreservesMessageAndAddsOutputLimitGuidance() throws {
    var stream = OpenAIStreamState()
    _ = try stream.consume(#"{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#)
    let message = "The model ended the turn without producing text."
    let envelope = #"{"error":{"message":"The model ended the turn without producing text.","code":"generation_failed","type":"server_error"}}"#
    #expect(throws: EndpointSessionError.server(message)) { try stream.consume(envelope) }
    let description = EndpointSessionError.server(message).localizedDescription
    #expect(description.hasPrefix(message))
    #expect(description.contains("may be too small"))
    #expect(description.contains("server and Lowlight"))
    #expect(description.contains("/set max-tokens 4096"))
    #expect(description.contains("/retry"))
}

@Test
func unrelatedServerErrorKeepsOriginalDescription() throws {
    var stream = OpenAIStreamState()
    let message = "The requested model is not loaded."
    let envelope = #"{"error":{"message":"The requested model is not loaded.","type":"server_error"}}"#
    #expect(throws: EndpointSessionError.server(message)) { try stream.consume(envelope) }
    #expect(EndpointSessionError.server(message).localizedDescription == message)
}

@Test
func streamEOFWithoutATerminalMarkerIsRejected() throws {
    var state = OpenAIStreamState()
    let content = ChatCompletionChunk(
        id: "chatcmpl-test",
        model: "gemma",
        choices: [.init(delta: .init(content: "partial"))]
    )
    let json = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)

    #expect(try state.consume(json) == ["partial"])
    #expect(state.answer == "partial")
    #expect(throws: EndpointSessionError.incompleteStream) {
        try state.validateCompletion()
    }
}

@Test
func doneOrFinishReasonMakesAStreamComplete() throws {
    let content = ChatCompletionChunk(
        id: "chatcmpl-test",
        model: "gemma",
        choices: [.init(delta: .init(content: "complete"))]
    )
    let finish = ChatCompletionChunk(
        id: "chatcmpl-test",
        model: "gemma",
        choices: [.init(delta: .init(), finishReason: "stop")]
    )
    let contentJSON = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
    let finishJSON = String(decoding: try JSONEncoder().encode(finish), as: UTF8.self)

    var finishState = OpenAIStreamState()
    _ = try finishState.consume(contentJSON)
    _ = try finishState.consume(finishJSON)
    try finishState.validateCompletion()

    var doneState = OpenAIStreamState()
    _ = try doneState.consume(contentJSON)
    _ = try doneState.consume("[DONE]")
    try doneState.validateCompletion()
}

@Test
func streamingUsageChunkIsCaptured() throws {
    let usage = OpenAIUsage(promptTokens: 12, completionTokens: 4, totalTokens: 16)
    let chunk = ChatCompletionChunk(
        id: "chatcmpl-usage",
        model: "gemma",
        choices: [],
        usage: usage
    )
    var state = OpenAIStreamState()

    _ = try state.consume(String(decoding: JSONEncoder().encode(chunk), as: UTF8.self))

    #expect(state.usage == usage)
}

@Test
func terminalRunnerPerformanceChunkIsCapturedWithoutStandardEnvelopeFields() throws {
    let json =
        """
        {"choices":[],"model_runner":{"performance":{"prompt_tokens_per_second":85.31,"tokens_per_second":14.72}}}
        """
    var state = OpenAIStreamState()

    #expect(try state.consume(json).isEmpty)
    #expect(state.performance?.promptTokensPerSecond == 85.31)
    #expect(state.performance?.tokensPerSecond == 14.72)
}

@Test
func sharedSettingsDecodeChatDefaults() throws {
    let json = Data(
        """
        {
          "chat": {
            "endpoint": "http://127.0.0.1:8080/v1",
            "model": "gemma",
            "apiKeyEnvironment": "MODEL_TOKEN",
            "maximumTokens": 256,
            "audioOutputDirectory": "~/Downloads/model-audio",
            "context": {
              "windowTokens": 32768,
              "safetyReserveTokens": 1024,
              "compactAtPercent": 85,
              "strategy": "slidingWindow",
              "systemPrompt": "Stay concise."
            }
          }
        }
        """.utf8
    )
    let settings = try JSONDecoder().decode(ModelStackSettings.self, from: json)

    #expect(settings.chat?.endpoint == "http://127.0.0.1:8080/v1")
    #expect(settings.chat?.model == "gemma")
    #expect(settings.chat?.apiKeyEnvironment == "MODEL_TOKEN")
    #expect(settings.chat?.maximumTokens == 256)
    #expect(settings.chat?.audioOutputDirectory == "~/Downloads/model-audio")
    #expect(settings.chat?.context?.windowTokens == 32_768)
    #expect(settings.chat?.context?.safetyReserveTokens == 1_024)
    #expect(settings.chat?.context?.compactAtPercent == 85)
    #expect(settings.chat?.context?.strategy == .slidingWindow)
    #expect(settings.chat?.context?.systemPrompt == "Stay concise.")
}
