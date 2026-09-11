import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ModelTransport
import Testing
@testable import ModelChatCore

@Suite("Responses endpoint sessions")
struct ResponsesSessionTests {
    @Test("Automatic API selection streams Responses and continues with only the new prompt")
    func responsesContinuation() async throws {
        let (session, fixture) = try makeSession(replies: [
            .text("First answer 🦉", id: "resp_first", inputTokens: 17, outputTokens: 3),
            .text("Second answer", id: "resp_second", inputTokens: 22, outputTokens: 4),
        ])
        let output = await ResponsesOutputRecorder()
        _ = try await session.generate(responseTo: "First prompt", reasoningEffort: .high, onChunk: { output.append($0) })
        _ = try await session.generate(responseTo: "Second prompt", onChunk: { output.append($0) })

        let requests = fixture.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.path == "/v1/responses" })
        #expect(requests[0].previousResponseID == nil)
        #expect(requests[0].messages == [.init(role: "user", content: "First prompt")])
        #expect(requests[0].body["model"] as? String == "test-model")
        #expect(requests[0].body["stream"] as? Bool == true)
        #expect(requests[0].body["store"] as? Bool == true)
        #expect(requests[0].body["max_output_tokens"] as? Int == 128)
        #expect(requests[0].body["max_tokens"] == nil)
        #expect((requests[0].body["reasoning"] as? [String: String])?["effort"] == "high")
        #expect(requests[1].previousResponseID == "resp_first")
        #expect(requests[1].messages == [.init(role: "user", content: "Second prompt")])
        #expect(await output.text == "First answer 🦉Second answer")
        #expect(await session.activeAPI() == .responses)
        #expect(await session.exportContext().turns == [
            .init(user: "First prompt", assistant: "First answer 🦉"),
            .init(user: "Second prompt", assistant: "Second answer"),
        ])
        let usage = await session.usageSnapshot()
        #expect(usage.reportedRequests == 2)
        #expect(usage.promptTokens == 39)
        #expect(usage.completionTokens == 7)
        #expect(usage.totalTokens == 46)
        #expect(usage.lastRequest == OpenAIUsage(promptTokens: 22, completionTokens: 4, totalTokens: 26, cachedTokens: 0))
    }

    @Test("Explicit Chat Completions retains the legacy request format")
    func explicitChat() async throws {
        let (session, fixture) = try makeSession(api: .chatCompletions, replies: [.chat("Legacy answer")])
        _ = try await session.generate(responseTo: "Hello", reasoningEffort: .low, onChunk: { _ in })
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests[0].path == "/v1/chat/completions")
        #expect(fixture.requests[0].body["max_tokens"] as? Int == 128)
        #expect(fixture.requests[0].body["reasoning_effort"] as? String == "low")
        #expect(await session.activeAPI() == .chatCompletions)
    }

    @Test("Automatic mode remembers an unavailable Responses route", arguments: [404, 405])
    func automaticFallback(status: Int) async throws {
        let (session, fixture) = try makeSession(replies: [.status(status), .chat("One"), .chat("Two")])
        _ = try await session.generate(responseTo: "First", onChunk: { _ in })
        _ = try await session.generate(responseTo: "Next", onChunk: { _ in })
        #expect(fixture.requests.map(\.path) == ["/v1/responses", "/v1/chat/completions", "/v1/chat/completions"])
        #expect(fixture.requests.last?.messages == [
            .init(role: "user", content: "First"), .init(role: "assistant", content: "One"),
            .init(role: "user", content: "Next"),
        ])
        #expect(await session.activeAPI() == .chatCompletions)
    }

    @Test("Model and authorization errors do not trigger a different API", arguments: [401, 403, 404])
    func noFallbackForServiceError(status: Int) async throws {
        let code = status == 404 ? "model_not_found" : "invalid_api_key"
        let (session, fixture) = try makeSession(replies: [.error(status, code: code, param: status == 404 ? "model" : nil)])
        await #expect(throws: (any Error).self) {
            try await session.generate(responseTo: "Hello", onChunk: { _ in })
        }
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests[0].path == "/v1/responses")
        #expect(await session.exportContext() == .init())
    }

    @Test("Explicit Responses mode never falls back to Chat Completions")
    func explicitResponsesDoesNotFallback() async throws {
        let (session, fixture) = try makeSession(api: .responses, replies: [.status(404)])
        await #expect(throws: (any Error).self) {
            try await session.generate(responseTo: "Hello", onChunk: { _ in })
        }
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests[0].path == "/v1/responses")
    }

    @Test("An expired stored response is retried once with the complete local history")
    func staleResponseRecovery() async throws {
        let (session, fixture) = try makeSession(replies: [
            .text("Answer", id: "resp_expired"),
            .error(404, code: "response_not_found", param: "previous_response_id"),
            .text("Recovered", id: "resp_recovered"),
            .text("Continued", id: "resp_next"),
        ])
        let output = await ResponsesOutputRecorder()
        _ = try await session.generate(responseTo: "First", onChunk: { output.append($0) })
        _ = try await session.generate(responseTo: "Next", onChunk: { output.append($0) })
        _ = try await session.generate(responseTo: "Third", onChunk: { output.append($0) })
        let requests = fixture.requests
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.path == "/v1/responses" })
        #expect(requests[1].previousResponseID == "resp_expired")
        #expect(requests[2].previousResponseID == nil)
        #expect(requests[2].messages == [
            .init(role: "user", content: "First"), .init(role: "assistant", content: "Answer"),
            .init(role: "user", content: "Next"),
        ])
        #expect(requests[3].previousResponseID == "resp_recovered")
        #expect(await output.text == "AnswerRecoveredContinued")
    }

    @Test("A failed stale-response retry does not loop or fall back")
    func staleResponseRetryIsBounded() async throws {
        let (session, fixture) = try makeSession(replies: [
            .text("Answer", id: "resp_expired"),
            .error(404, code: "response_not_found", param: "previous_response_id"),
            .error(404, code: "response_not_found", param: "previous_response_id"),
        ])
        _ = try await session.generate(responseTo: "First", onChunk: { _ in })
        let original = await session.exportContext()
        await #expect(throws: (any Error).self) {
            try await session.generate(responseTo: "Next", onChunk: { _ in })
        }
        #expect(fixture.requests.count == 3)
        #expect(await session.exportContext() == original)
    }

    @Test("Local context edits discard the server continuation", arguments: ContextMutation.allCases)
    func contextMutationInvalidatesContinuation(mutation: ContextMutation) async throws {
        let (session, fixture) = try makeSession(replies: [.text("Answer", id: "resp_old"), .text("New answer", id: "resp_new")])
        _ = try await session.generate(responseTo: "First", onChunk: { _ in })
        switch mutation {
        case .clear: _ = await session.clear()
        case .restore: _ = try await session.restoreContext(.init(turns: [.init(user: "Restored", assistant: "Saved answer")]))
        case .instructions: _ = try await session.updateSystemPrompt("New instructions")
        }
        _ = try await session.generate(responseTo: "Next", onChunk: { _ in })
        let request = fixture.requests[1]
        #expect(request.previousResponseID == nil)
        #expect(request.messages.last == .init(role: "user", content: "Next"))
        switch mutation {
        case .clear: #expect(request.messages.count == 1)
        case .restore: #expect(request.messages.first == .init(role: "user", content: "Restored"))
        case .instructions:
            #expect(request.messages.first == .init(role: "system", content: "New instructions") || request.body["instructions"] as? String == "New instructions")
            #expect(request.messages.contains(.init(role: "assistant", content: "Answer")))
        }
    }

    @Test("A truncated stream preserves both local context and the last successful response ID")
    func truncatedStreamRollback() async throws {
        let (session, fixture) = try makeSession(replies: [
            .text("Answer", id: "resp_good"), .truncated("Partial", id: "resp_broken"),
            .text("Retry answer", id: "resp_retry"),
        ])
        _ = try await session.generate(responseTo: "First", onChunk: { _ in })
        let original = await session.exportContext()
        await #expect(throws: EndpointSessionError.incompleteStream) {
            try await session.generate(responseTo: "Next", onChunk: { _ in })
        }
        #expect(await session.exportContext() == original)
        _ = try await session.generate(responseTo: "Next", onChunk: { _ in })
        #expect(fixture.requests[2].previousResponseID == "resp_good")
        #expect(await session.exportContext().turns.last == .init(user: "Next", assistant: "Retry answer"))
    }

    @Test("A failed semantic response cannot commit its partial text or response ID")
    func failedResponseRollback() async throws {
        let (session, fixture) = try makeSession(replies: [.failed("Partial", id: "resp_failed"), .text("Retry answer", id: "resp_retry")])
        await #expect(throws: (any Error).self) {
            try await session.generate(responseTo: "First", onChunk: { _ in })
        }
        #expect(await session.exportContext() == .init())
        _ = try await session.generate(responseTo: "First", onChunk: { _ in })
        #expect(fixture.requests.count == 2)
        #expect(fixture.requests[1].previousResponseID == nil)
    }

    @Test("Cancellation preserves local context and the previous successful continuation")
    func cancellationRollback() async throws {
        let (session, fixture) = try makeSession(replies: [.text("Answer", id: "resp_good"), .hold, .text("Retry", id: "resp_retry")])
        _ = try await session.generate(responseTo: "First", onChunk: { _ in })
        let original = await session.exportContext()
        let task = Task { try await session.generate(responseTo: "Next", onChunk: { _ in }) }
        do { try await fixture.waitForRequests(2) }
        catch { task.cancel(); _ = try? await task.value; throw error }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await session.exportContext() == original)
        _ = try await session.generate(responseTo: "Next", onChunk: { _ in })
        #expect(fixture.requests[2].previousResponseID == "resp_good")
    }

    @Test("A length-limited answer is shown but its incomplete response ID is not reused")
    func incompleteAnswerDoesNotCreateContinuation() async throws {
        let (session, fixture) = try makeSession(replies: [.incomplete("Partial answer", id: "resp_limited"), .text("Next answer", id: "resp_next")])
        _ = try await session.generate(responseTo: "First", onChunk: { _ in })
        _ = try await session.generate(responseTo: "Next", onChunk: { _ in })
        #expect(fixture.requests[1].previousResponseID == nil)
        #expect(fixture.requests[1].messages.contains(.init(role: "assistant", content: "Partial answer")))
    }

    @Test("Checkpoint summaries are stateless and invalidate the user conversation cursor")
    func statelessCheckpoint() async throws {
        let (session, fixture) = try makeSession(strategy: .checkpoint, replies: [
            .text("Answer one", id: "resp_one"), .text("Answer two", id: "resp_two"),
            .text("Remember the first decision.", id: "resp_summary"), .text("Final answer", id: "resp_final"),
        ])
        _ = try await session.generate(responseTo: "First decision", onChunk: { _ in })
        _ = try await session.generate(responseTo: "Second decision", onChunk: { _ in })
        _ = try await session.compact()
        _ = try await session.generate(responseTo: "Continue", onChunk: { _ in })
        let requests = fixture.requests
        #expect(requests.count == 4)
        #expect(requests[1].previousResponseID == "resp_one")
        #expect(requests[2].body["store"] as? Bool == false)
        #expect(requests[2].previousResponseID == nil)
        #expect(requests[2].messages.first?.content?.contains("continuation notes") == true)
        #expect(requests[3].previousResponseID == nil)
        #expect(requests[3].messages.contains { $0.content?.contains("Remember the first decision.") == true })
        #expect(await session.exportContext().summary == "Remember the first decision.")
    }

    @Test("Sliding-window omission sends fresh Responses input instead of inheriting omitted history")
    func slidingWindowInvalidatesContinuation() async throws {
        let firstPrompt = String(repeating: "u", count: 3_000)
        let firstAnswer = String(repeating: "a", count: 300)
        let nextPrompt = String(repeating: "n", count: 1_200)
        let (session, fixture) = try makeSession(replies: [
            .text(firstAnswer, id: "resp_old_window"), .text("Fresh window", id: "resp_new_window"),
        ])
        _ = try await session.generate(responseTo: firstPrompt, onChunk: { _ in })
        let report = try await session.generate(responseTo: nextPrompt, onChunk: { _ in })
        #expect(report.omittedTurns == 1)
        #expect(fixture.requests[1].previousResponseID == nil)
        #expect(fixture.requests[1].messages == [.init(role: "user", content: nextPrompt)])
        #expect(await session.exportContext().turns == [.init(user: nextPrompt, assistant: "Fresh window")])
    }

    @Test("Failed final answers roll back automatic checkpoints and preserve the prior cursor", arguments: [false, true])
    func automaticCheckpointFailureRollback(retryLargePrompt: Bool) async throws {
        var replies: [ResponsesReply] = [
            .text("Live answer", id: "resp_good"),
            .text("Prepared notes", id: "resp_summary_discarded"), .status(500),
        ]
        if retryLargePrompt {
            replies += [.text("Retried notes", id: "resp_summary_retry"), .text("Final answer", id: "resp_final")]
        } else {
            replies += [.text("Original context retained", id: "resp_after_failure")]
        }
        let (session, fixture) = try makeSession(strategy: .checkpoint, replies: replies)
        let history = ConversationContextState(turns: (0..<3).map {
            .init(user: "\($0)" + String(repeating: "u", count: 299), assistant: String(repeating: "a", count: 300))
        })
        _ = try await session.restoreContext(history)
        _ = try await session.generate(responseTo: "Live prompt", onChunk: { _ in })
        let original = await session.exportContext()
        let largePrompt = String(repeating: "n", count: 2_500)
        await #expect(throws: EndpointSessionError.httpStatus(500)) {
            try await session.generate(responseTo: largePrompt, onChunk: { _ in })
        }
        #expect(await session.exportContext() == original)
        #expect(fixture.requests.count == 3)
        #expect(fixture.requests[1].body["store"] as? Bool == false)
        #expect(fixture.requests[1].previousResponseID == nil)
        #expect(fixture.requests[2].previousResponseID == nil)
        #expect(fixture.requests[2].messages.contains { $0.content?.contains("Prepared notes") == true })

        if retryLargePrompt {
            _ = try await session.generate(responseTo: largePrompt, onChunk: { _ in })
            #expect(fixture.requests.count == 5)
            #expect(fixture.requests[3].body["store"] as? Bool == false)
            #expect(fixture.requests[3].previousResponseID == nil)
            func checkpointTranscript(_ request: ResponsesCapturedRequest) throws -> [OpenAIMessage] {
                let content = try #require(request.messages.last?.content)
                let prefix = "Conversation history (JSON):\n"
                try #require(content.hasPrefix(prefix))
                return try JSONDecoder().decode([OpenAIMessage].self, from: Data(content.dropFirst(prefix.count).utf8))
            }
            #expect(fixture.requests[3].messages.first == fixture.requests[1].messages.first)
            let firstTranscript = try checkpointTranscript(fixture.requests[1])
            let retriedTranscript = try checkpointTranscript(fixture.requests[3])
            #expect(firstTranscript == history.turns.flatMap(\.messages))
            #expect(retriedTranscript == firstTranscript)
            #expect(fixture.requests[4].previousResponseID == nil)
            #expect(fixture.requests[4].messages.contains { $0.content?.contains("Retried notes") == true })
            #expect(await session.exportContext().summary == "Retried notes")
        } else {
            _ = try await session.generate(responseTo: "Short follow-up", onChunk: { _ in })
            #expect(fixture.requests.count == 4)
            #expect(fixture.requests[3].previousResponseID == "resp_good")
            #expect(fixture.requests[3].messages == [.init(role: "user", content: "Short follow-up")])
            #expect(await session.exportContext().summary == nil)
        }
    }

    @Test("Fragmented multiline SSE data fields form one semantic Responses event")
    func multilineSSEFrames() async throws {
        let answer = "First line\nSecond line 🦉"
        let (session, fixture) = try makeSession(replies: [.multiline(answer, id: "resp_multiline")])
        let output = await ResponsesOutputRecorder()
        _ = try await session.generate(responseTo: "Two lines", onChunk: { output.append($0) })
        #expect(fixture.requests.count == 1)
        #expect(await output.text == answer)
        #expect(await session.exportContext().turns == [.init(user: "Two lines", assistant: answer)])
    }

    enum ContextMutation: String, CaseIterable, Sendable { case clear, restore, instructions }

    private func makeSession(
        api: OpenAIAPI = .auto, strategy: ContextStrategy = .slidingWindow,
        replies: [ResponsesReply]
    ) throws -> (EndpointModelSession, ResponsesFixture) {
        let fixture = ResponsesFixture(replies: replies)
        let host = "\(UUID().uuidString.lowercased()).responses.test"
        ResponsesURLProtocol.fixtures.register(fixture, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesURLProtocol.self]
        return (try EndpointModelSession(
            model: "test-model", endpoint: "https://\(host)/v1", api: api, maximumTokens: 128,
            contextWindowTokens: 1_200, contextSafetyReserveTokens: 0,
            contextCompactAtPercent: 100, contextStrategy: strategy,
            urlSession: URLSession(configuration: configuration)
        ), fixture)
    }
}

@MainActor
private final class ResponsesOutputRecorder {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}

private enum ResponsesReply: Sendable {
    case text(String, id: String, inputTokens: Int = 10, outputTokens: Int = 2)
    case chat(String)
    case status(Int)
    case error(Int, code: String, param: String?)
    case truncated(String, id: String)
    case failed(String, id: String)
    case incomplete(String, id: String)
    case multiline(String, id: String)
    case hold
}

private struct ResponsesCapturedRequest: @unchecked Sendable {
    let path: String
    let body: [String: Any]
    var previousResponseID: String? { body["previous_response_id"] as? String }
    var messages: [OpenAIMessage] {
        let values = body["input"] as? [[String: Any]] ?? body["messages"] as? [[String: Any]] ?? []
        return values.compactMap { item in
            guard let role = item["role"] as? String else { return nil }
            let content = item["content"] as? String ?? (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            return .init(role: role, content: content)
        }
    }
}

private final class ResponsesFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ResponsesReply]
    private var captured: [ResponsesCapturedRequest] = []
    init(replies: [ResponsesReply]) { self.replies = replies }
    var requests: [ResponsesCapturedRequest] { lock.withLock { captured } }

    func receive(_ request: URLRequest) throws -> ResponsesReply {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return lock.withLock {
            captured.append(.init(path: request.url!.path, body: payload))
            return replies.isEmpty ? .status(599) : replies.removeFirst()
        }
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<400 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
}

private final class ResponsesFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: ResponsesFixture] = [:]
    func register(_ fixture: ResponsesFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    func fixture(for host: String) -> ResponsesFixture? { lock.withLock { fixtures[host] } }
}

private final class ResponsesURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = ResponsesFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".responses.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url, let fixture = Self.fixtures.fixture(for: url.host ?? "") else { throw URLError(.badURL) }
            let reply = try fixture.receive(request)
            let status: Int
            let data: Data
            switch reply {
            case .hold: return
            case .status(let code): status = code; data = Data()
            case .error(let code, let errorCode, let param):
                status = code
                var error: [String: Any] = ["message": "Request rejected: \(errorCode)", "type": "invalid_request_error", "code": errorCode]
                if let param { error["param"] = param }
                data = try JSONSerialization.data(withJSONObject: ["error": error])
            case .chat(let text):
                status = 200
                let chunk = ChatCompletionChunk(id: "chat_test", model: "test-model", choices: [.init(delta: .init(content: text), finishReason: "stop")])
                data = Data("data: \(String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
            case .text(let text, let id, let inputTokens, let outputTokens):
                status = 200
                data = try Self.responseStream(text: text, id: id, status: "completed", inputTokens: inputTokens, outputTokens: outputTokens)
            case .truncated(let text, let id):
                status = 200
                data = try Self.responseStream(text: text, id: id, status: nil)
            case .failed(let text, let id):
                status = 200
                data = try Self.responseStream(text: text, id: id, status: "failed")
            case .incomplete(let text, let id):
                status = 200
                data = try Self.responseStream(text: text, id: id, status: "incomplete")
            case .multiline(let text, let id):
                status = 200
                data = try Self.responseStream(text: text, id: id, status: "completed", multiline: true)
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Split across both UTF-8 and SSE framing boundaries to exercise the transport buffer.
            let fragmentSize: Int
            if case .multiline = reply { fragmentSize = 1 } else { fragmentSize = 37 }
            for offset in stride(from: 0, to: data.count, by: fragmentSize) {
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + fragmentSize, data.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}

    private static func responseStream(text: String, id: String, status: String?, inputTokens: Int = 10, outputTokens: Int = 2, multiline: Bool = false) throws -> Data {
        let part: [String: Any] = ["type": "output_text", "text": text, "annotations": []]
        let item: [String: Any] = ["id": "msg_\(id)", "type": "message", "role": "assistant", "status": status ?? "in_progress", "content": [part]]
        var response: [String: Any] = ["id": id, "object": "response", "model": "test-model", "created_at": 1, "status": "in_progress", "output": []]
        var events: [[String: Any]] = [
            ["type": "response.created", "response": response],
            ["type": "response.output_item.added", "output_index": 0, "item": ["id": "msg_\(id)", "type": "message", "role": "assistant", "status": "in_progress", "content": []]],
            ["type": "response.content_part.added", "output_index": 0, "content_index": 0, "item_id": "msg_\(id)", "part": ["type": "output_text", "text": "", "annotations": []]],
            ["type": "response.output_text.delta", "output_index": 0, "content_index": 0, "item_id": "msg_\(id)", "delta": text],
        ]
        if let status {
            response["status"] = status
            response["output"] = [item]
            response["usage"] = ["input_tokens": inputTokens, "output_tokens": outputTokens, "total_tokens": inputTokens + outputTokens,
                                 "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0]]
            if status == "failed" { response["error"] = ["code": "server_error", "message": "Generation failed"] }
            if status == "incomplete" { response["incomplete_details"] = ["reason": "max_output_tokens"] }
            events += [
                ["type": "response.output_text.done", "output_index": 0, "content_index": 0, "item_id": "msg_\(id)", "text": text],
                ["type": "response.content_part.done", "output_index": 0, "content_index": 0, "item_id": "msg_\(id)", "part": part],
                ["type": "response.output_item.done", "output_index": 0, "item": item],
                ["type": "response.\(status)", "response": response],
            ]
        }
        return try Data(events.enumerated().map { index, event in
            var payload = event
            payload["sequence_number"] = index
            let options: JSONSerialization.WritingOptions = multiline ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
            let json = try JSONSerialization.data(withJSONObject: payload, options: options)
            if multiline {
                let fields = String(decoding: json, as: UTF8.self).components(separatedBy: "\n").map { "data: \($0)\r\n" }.joined()
                return ": heartbeat\r\nid: \(index)\r\nevent: \(event["type"] as! String)\r\n" + fields + "\r\n"
            }
            return "event: \(event["type"] as! String)\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
        }.joined().utf8)
    }
}
