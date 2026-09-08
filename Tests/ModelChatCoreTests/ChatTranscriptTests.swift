import Foundation
import Testing
@testable import ModelChatCore

@Test
func beginningATurnAddsUserAndStreamingAssistantMessages() {
    var transcript = ChatTranscript()

    let responseID = transcript.beginTurn(prompt: "Hello")

    #expect(transcript.messages.count == 2)
    #expect(transcript.messages[0].role == .user)
    #expect(transcript.messages[0].text == "Hello")
    #expect(transcript.messages[1].id == responseID)
    #expect(transcript.messages[1].role == .assistant)
    #expect(transcript.messages[1].state == .streaming)
}

@Test
func streamedChunksAccumulateAndFinish() {
    var transcript = ChatTranscript()
    let responseID = transcript.beginTurn(prompt: "Count")

    transcript.append("one", to: responseID)
    transcript.append(" two", to: responseID)
    transcript.finish(responseID: responseID)

    #expect(transcript.messages[1].text == "one two")
    #expect(transcript.messages[1].state == .complete)
}

@Test
func generationErrorsStayVisibleInTheTranscript() {
    var transcript = ChatTranscript()
    let responseID = transcript.beginTurn(prompt: "Hello")

    transcript.fail(responseID: responseID, description: "model failed")

    #expect(transcript.messages[1].text == "Error: model failed")
    #expect(transcript.messages[1].state == .failed)
}

@Test
func clearRemovesAllMessages() {
    var transcript = ChatTranscript()
    _ = transcript.beginTurn(prompt: "Hello")

    transcript.clear()

    #expect(transcript.messages.isEmpty)
}

@Test
func localNoticesRemainDistinctFromModelTurns() {
    var transcript = ChatTranscript()

    transcript.addNotice("Context is at 50%.")

    #expect(transcript.messages.count == 1)
    #expect(transcript.messages[0].role == .notice)
    #expect(transcript.messages[0].text == "Context is at 50%.")
    #expect(transcript.messages[0].state == .complete)
}
