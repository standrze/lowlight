import Foundation
import ModelTransport
import Testing
@testable import ModelChatCore

@Suite("Responses wire and semantic streaming")
struct ResponsesStreamTests {
    @Test
    func requestUsesResponsesFieldsAndOmitsUnsetOptions() throws {
        let request = ResponsesRequest(
            model: "midnight", input: [.init(role: "user", content: "hello")],
            store: true, previousResponseID: "resp_previous", maxOutputTokens: 128,
            temperature: 0, reasoningEffort: .medium)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["stream"] as? Bool == true)
        #expect(object["store"] as? Bool == true)
        #expect(object["previous_response_id"] as? String == "resp_previous")
        #expect(object["max_output_tokens"] as? Int == 128)
        #expect((object["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        #expect((object["input"] as? [[String: Any]])?.first?["content"] as? String == "hello")
        #expect(object["messages"] == nil)
        #expect(object["max_tokens"] == nil)
        #expect(object["stream_options"] == nil)
        #expect(try JSONDecoder().decode(ResponsesRequest.self, from: JSONEncoder().encode(request)) == request)
        let stateless = ResponsesRequest(model: "midnight", input: [], store: false)
        let statelessObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stateless)) as? [String: Any])
        #expect(statelessObject["store"] as? Bool == false)
        #expect(statelessObject["previous_response_id"] == nil)
        #expect(statelessObject["reasoning"] == nil)
    }

    @Test
    func endpointNormalizationHandlesResponsesAndProxyPrefixes() throws {
        #expect(try OpenAIEndpoint.responsesURL(from: "http://localhost:8080").absoluteString == "http://localhost:8080/v1/responses")
        #expect(try OpenAIEndpoint.responsesURL(from: "http://localhost:8080/proxy/v1/chat/completions").absoluteString == "http://localhost:8080/proxy/v1/responses")
        #expect(try OpenAIEndpoint.responsesURL(from: "http://localhost:8080/proxy/v1/responses").absoluteString == "http://localhost:8080/proxy/v1/responses")
        #expect(try OpenAIEndpoint.chatCompletionsURL(from: "http://localhost:8080/proxy/v1/responses").absoluteString == "http://localhost:8080/proxy/v1/chat/completions")
        #expect(try OpenAIEndpoint.modelsURL(from: "http://localhost:8080/proxy/v1/responses").absoluteString == "http://localhost:8080/proxy/v1/models")
        #expect(try OpenAIEndpoint.speechURL(from: "http://localhost:8080/proxy/v1/responses").absoluteString == "http://localhost:8080/proxy/v1/audio/speech")
        #expect(try OpenAIEndpoint.responsesURL(from: "http://localhost:8080/myresponses").absoluteString == "http://localhost:8080/myresponses/v1/responses")
        #expect(try OpenAIEndpoint.chatCompletionsURL(from: "http://localhost:8080/chat/completions").absoluteString == "http://localhost:8080/chat/completions")
        #expect(try OpenAIEndpoint.chatCompletionsURL(from: "https://host/custom/chat/completions").absoluteString == "https://host/custom/chat/completions")
        #expect(try OpenAIEndpoint.responsesURL(from: "https://host/customgateway/api/chat/completions").absoluteString == "https://host/customgateway/api/responses")
        #expect(try OpenAIEndpoint.responsesURL(from: "https://host/customgateway/api/responses").absoluteString == "https://host/customgateway/api/responses")
        #expect(try OpenAIEndpoint.chatCompletionsURL(from: "https://host/customgateway/api/responses").absoluteString == "https://host/customgateway/api/chat/completions")
        #expect(try OpenAIEndpoint.modelsURL(from: "https://host/customgateway/api/responses").absoluteString == "https://host/customgateway/api/models")
        #expect(try OpenAIEndpoint.speechURL(from: "https://host/customgateway/api/responses").absoluteString == "https://host/customgateway/api/audio/speech")
    }

    @Test
    func errorEnvelopeRetainsStaleResponseInformationWithoutType() throws {
        let data = Data(#"{"error":{"message":"expired","code":"response_not_found","param":"previous_response_id"}}"#.utf8)
        let error = try JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data).error
        #expect(error.message == "expired")
        #expect(error.type == "server_error")
        #expect(error.code == "response_not_found")
        #expect(error.param == "previous_response_id")
    }

    @Test
    func midnightLifecycleDoesNotDuplicateDonePayloadsAndCapturesUsage() throws {
        var state = ResponsesStreamState()
        _ = try state.consume(#"{"type":"response.created","response":{"id":"resp_test","status":"in_progress","output":[]}}"#)
        _ = try state.consume(#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","content":[]}}"#)
        _ = try state.consume(#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}"#)
        #expect(try state.consume(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hello"}"#) == ["Hello"])
        #expect(try state.consume(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":" world"}"#) == [" world"])
        #expect(try state.consume(#"{"type":"response.output_text.done","output_index":0,"content_index":0,"text":"Hello world"}"#).isEmpty)
        #expect(try state.consume(#"{"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hello world"}}"#).isEmpty)
        #expect(try state.consume(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello world"}]}}"#).isEmpty)
        #expect(try state.consume(terminal("Hello world", usage: ["input_tokens": 14, "output_tokens": 2, "total_tokens": 16])).isEmpty)
        try state.validateCompletion()
        #expect(state.answer == "Hello world")
        #expect(state.responseID == "resp_test")
        #expect(state.finishReason == "stop")
        #expect(state.usage == .init(promptTokens: 14, completionTokens: 2, totalTokens: 16))
    }

    @Test
    func doneAndTerminalEventsCanSupplyUnstreamedText() throws {
        var state = ResponsesStreamState()
        #expect(try state.consume(#"{"type":"response.output_text.delta","delta":"Hel"}"#) == ["Hel"])
        #expect(try state.consume(#"{"type":"response.output_text.done","text":"Hello"}"#) == ["lo"])
        #expect(try state.consume(terminal("Hello world")) == [" world"])
        try state.validateCompletion()
        #expect(state.answer == "Hello world")

        var terminalOnly = ResponsesStreamState()
        #expect(try terminalOnly.consume(terminal("A complete response")) == ["A complete response"])
        try terminalOnly.validateCompletion()
    }

    @Test
    func unicodeCombiningCharactersReconcileWithoutLostBytes() throws {
        var state = ResponsesStreamState()
        _ = try state.consume(#"{"type":"response.output_text.delta","delta":"a"}"#)
        let text = "a\u{301}"
        #expect(try state.consume(terminal(text)) == ["\u{301}"])
        #expect(Array(state.answer.utf8) == Array(text.utf8))
        try state.validateCompletion()
    }

    @Test
    func missingOrContradictoryFinalOutputIsRejected() throws {
        var state = ResponsesStreamState()
        _ = try state.consume(#"{"type":"response.output_text.delta","delta":"Hello"}"#)
        #expect(throws: EndpointSessionError.invalidResponse) { try state.consume(terminal("Different")) }
        #expect(throws: EndpointSessionError.invalidResponse) { try state.consume(#"{"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[]}}"#) }
        #expect(throws: EndpointSessionError.invalidResponse) { try state.consume(#"{"type":"response.completed","response":{"id":"resp_test","status":"completed"}}"#) }
    }

    @Test
    func sentinelAndTextDoneDoNotHideATruncatedStream() throws {
        var state = ResponsesStreamState()
        _ = try state.consume(#"{"type":"response.output_text.delta","delta":"partial"}"#)
        _ = try state.consume(#"{"type":"response.output_text.done","text":"partial"}"#)
        _ = try state.consume("[DONE]")
        #expect(!state.reachedTerminalEvent)
        #expect(throws: EndpointSessionError.incompleteStream) { try state.validateTerminalEvent() }
    }

    @Test
    func tokenLimitKeepsVisiblePartialAnswerAndReportsEmptyReasoningLimit() throws {
        var state = ResponsesStreamState()
        _ = try state.consume(terminal("partial", status: "incomplete", incompleteReason: "max_output_tokens"))
        try state.validateCompletion()
        #expect(state.finishReason == "length")
        var empty = ResponsesStreamState()
        _ = try empty.consume(terminal("", status: "incomplete", incompleteReason: "max_output_tokens"))
        #expect(throws: EndpointSessionError.outputLimitReached) { try empty.validateCompletion() }
    }

    @Test
    func refusalsAreVisibleText() throws {
        var state = ResponsesStreamState()
        #expect(try state.consume(#"{"type":"response.refusal.delta","delta":"I cannot "}"#) == ["I cannot "])
        #expect(try state.consume(#"{"type":"response.refusal.done","refusal":"I cannot help."}"#) == ["help."])
        _ = try state.consume(#"{"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"I cannot help."}]}]}}"#)
        try state.validateCompletion()
        #expect(state.answer == "I cannot help.")
    }

    @Test
    func reasoningIsSeparateAndNotRepeatedAtCompletion() throws {
        var state = ResponsesStreamState()
        #expect(try state.consume(#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"Thinking"}"#).isEmpty)
        #expect(state.reasoningChunks == ["Thinking"])
        _ = try state.consume(#"{"type":"response.reasoning_summary_text.done","output_index":0,"summary_index":0,"text":"Thinking carefully"}"#)
        #expect(state.reasoningChunks == [" carefully"])
        _ = try state.consume(#"{"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"Answer"}"#)
        #expect(state.reasoningChunks.isEmpty)
        _ = try state.consume(#"{"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Thinking carefully"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}]}}"#)
        #expect(state.reasoningChunks.isEmpty)
        #expect(state.answer == "Answer")
        try state.validateCompletion()
    }

    @Test
    func terminalOnlyMultiplePartsPreserveOrder() throws {
        var state = ResponsesStreamState()
        let chunks = try state.consume(#"{"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"One"},{"type":"output_text","text":" two"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":" three"}]}]}}"#)
        #expect(chunks == ["One", " two", " three"])
        #expect(state.answer == "One two three")
        try state.validateCompletion()
    }

    @Test
    func failedAndErrorEventsPropagateServerMessage() throws {
        var state = ResponsesStreamState()
        #expect(throws: EndpointSessionError.server("Out of memory")) {
            try state.consume(#"{"type":"response.failed","response":{"id":"resp_test","status":"failed","error":{"code":"server_error","message":"Out of memory"}}}"#)
        }
        #expect(throws: EndpointSessionError.server("Bad request")) {
            try state.consume(#"{"type":"error","code":"invalid_request","message":"Bad request"}"#)
        }
    }

    @Test
    func toolAndUnknownOutputCannotBecomeASuccessfulChat() throws {
        var state = ResponsesStreamState()
        #expect(throws: (any Error).self) {
            try state.consume(#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","name":"shell","arguments":"{}"}}"#)
        }
        #expect(throws: (any Error).self) {
            try state.consume(#"{"type":"response.completed","response":{"id":"resp_test","status":"completed","output":[{"type":"image_generation_call"}]}}"#)
        }
        #expect(!state.reachedTerminalEvent)
    }

    @Test
    func bothAPIsCaptureCachedInputTokens() throws {
        let chat = Data(#"{"prompt_tokens":200,"completion_tokens":2,"total_tokens":202,"prompt_tokens_details":{"cached_tokens":128}}"#.utf8)
        #expect(try JSONDecoder().decode(OpenAIUsage.self, from: chat).cachedTokens == 128)
        var state = ResponsesStreamState()
        _ = try state.consume(terminal("Answer", usage: ["input_tokens": 200, "output_tokens": 2,
            "total_tokens": 202, "input_tokens_details": ["cached_tokens": 128]]))
        #expect(state.usage?.cachedTokens == 128)
        try state.validateCompletion()
    }

    private func terminal(
        _ text: String, status: String = "completed", incompleteReason: String? = nil,
        usage: [String: Any]? = nil
    ) throws -> String {
        var response: [String: Any] = [
            "id": "resp_test", "status": status,
            "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]],
        ]
        if let incompleteReason { response["incomplete_details"] = ["reason": incompleteReason] }
        if let usage { response["usage"] = usage }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["type": "response.\(status)", "response": response]), as: UTF8.self)
    }
}
