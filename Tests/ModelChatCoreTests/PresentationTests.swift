import Foundation
import ModelTransport
import Testing
@testable import ModelChatCore

@Test func reasoningDeltasStayOutOfAnswerContext() throws {
    var stream = OpenAIStreamState()
    #expect(try stream.consume(#"{"choices":[{"index":0,"delta":{"reasoning_content":"Considering"}}]}"#).isEmpty)
    #expect(stream.reasoningChunks == ["Considering"])
    #expect(stream.answer.isEmpty)
    #expect(try stream.consume(#"{"choices":[{"index":0,"delta":{"reasoning":" alternatives","content":"**Hello**"}}]}"#) == ["**Hello**"])
    #expect(stream.reasoningChunks == [" alternatives"])
    #expect(stream.answer == "**Hello**")
    _ = try stream.consume("[DONE]")
    #expect(stream.reasoningChunks.isEmpty)
    try stream.validateCompletion()
}

@Test func reasoningOnlyIsNotAcceptedAsAFinalAnswer() throws {
    var stream = OpenAIStreamState()
    _ = try stream.consume(#"{"choices":[{"index":0,"delta":{"reasoning_content":"Still thinking"},"finish_reason":"length"}]}"#)
    #expect(throws: EndpointSessionError.emptyResponse) { try stream.validateCompletion() }
}

@Test func effortUsesWireFieldAndDefaultsToOmission() throws {
    let request = ChatCompletionRequest(model: "test", messages: [], reasoningEffort: .high)
    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["reasoning_effort"] as? String == "high")
    let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatCompletionRequest(model: "test", messages: []))) as? [String: Any]
    #expect(defaults?["reasoning_effort"] == nil)
}

@Test func savedReasoningAndEffortRoundTripAndOldSnapshotsLoad() throws {
    var transcript = ChatTranscript()
    let id = transcript.beginTurn(prompt: "hi")
    transcript.appendReasoning("Considering the greeting", to: id)
    transcript.append("Hello", to: id)
    transcript.finish(responseID: id)
    let saved = SavedConversation(model: "test", endpoint: "http://localhost:8081/v1", transcript: transcript, reasoningEffort: .medium)
    let data = try JSONEncoder().encode(saved)
    #expect(try JSONDecoder().decode(SavedConversation.self, from: data) == saved)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "reasoningEffort")
    var legacyTranscript = try #require(json["transcript"] as? [String: Any])
    var messages = try #require(legacyTranscript["messages"] as? [[String: Any]])
    for index in messages.indices { messages[index].removeValue(forKey: "reasoning") }
    legacyTranscript["messages"] = messages
    json["transcript"] = legacyTranscript
    let legacy = try JSONDecoder().decode(SavedConversation.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.reasoningEffort == nil)
    #expect(legacy.transcript.messages.last?.reasoning == nil)
    #expect(legacy.transcript.messages.last?.text == "Hello")
}

@Test func markdownFormatsEmphasisAndPreservesCode() {
    let spans = ChatMarkdown.spans("**Bold** and *italic* with `**literal**`.")
    #expect(spans.map(\.text).joined() == "Bold and italic with **literal**.")
    #expect(spans.contains { $0.text == "Bold" && $0.bold })
    #expect(spans.contains { $0.text == "italic" && $0.italic })
    #expect(spans.contains { $0.text == "**literal**" && $0.code && !$0.bold })
    let block = ChatMarkdown.spans("```ruby\n**literal**\n```\n# Heading")
    #expect(block.contains { $0.text == "**literal**\n" && $0.code && !$0.bold })
    #expect(block.last?.text == "Heading")
    #expect(block.last?.bold == true)
}

@Test func sseLinesPreserveUTF8AcrossNetworkChunksAndFinalUnterminatedLine() {
    let text = "data: {\"text\":\"月◒\"}\r\n\ndata: [DONE]"
    var buffer = SSELineBuffer()
    var lines: [String] = []
    for byte in text.utf8 { lines += buffer.append(Data([byte])) }
    #expect(lines == ["data: {\"text\":\"月◒\"}\r", ""])
    #expect(buffer.finish() == ["data: [DONE]"])
    #expect(buffer.finish().isEmpty)
}
