import Foundation
import ModelTransport
import Testing
@testable import ModelChatCore

@Suite("Conversation checkpoint endpoint")
struct CheckpointSessionTests {
    @Test("Automatic checkpoint preserves the current prompt, recent turns and canonical instructions")
    func automaticCheckpoint() async throws {
        let (session, fixture) = try makeSession(replies: [.text("User chose Ruby; keep the existing design."), .text("Final answer")])
        let original = history()
        try await session.restoreContext(original)
        let prompt = "Continue exactly from this prompt."
        let progress = await CompactionProgressRecorder()
        let report = try await session.generate(
            responseTo: prompt,
            onCompaction: { progress.record($0, requestCount: fixture.requests.count) },
            onChunk: { _ in }
        )
        let saved = await session.exportContext()
        let requests = fixture.requests

        #expect(requests.count == 2)
        #expect(await progress.states == [true, false])
        #expect(await progress.requestCounts == [0, 1])
        #expect(requests[0].messages.first?.content?.contains("continuation notes") == true)
        #expect(requests[0].messages.last?.content?.contains(original.turns[0].user.content!) == true)
        #expect(requests[1].messages.first?.content == "Canonical instructions")
        #expect(requests[1].messages.last?.content == prompt)
        #expect(requests[1].messages[1].role == "user")
        #expect(requests[1].messages[2].role == "assistant")
        #expect(requests[1].messages[2].content?.contains("User chose Ruby") == true)
        #expect(saved.summary == "User chose Ruby; keep the existing design.")
        #expect(saved.turns.dropLast() == original.turns.suffix(saved.turns.count - 1))
        #expect(saved.turns.last == .init(user: prompt, assistant: "Final answer"))
        #expect(report.omittedTurns == original.turns.count - saved.turns.count + 1)
        #expect(report.context.hasSummary)
        for request in requests {
            #expect(ApproximateTokenEstimator().estimate(request.messages) <= 1_072)
            #expect(request.maxTokens! <= 128)
        }
    }

    @Test("A truncated checkpoint preserves all history without requesting a final answer")
    func truncatedCheckpointRollback() async throws {
        let (session, fixture) = try makeSession(replies: [.text("unfinished notes", finishReason: "length")])
        let original = history()
        try await session.restoreContext(original)
        let progress = await CompactionProgressRecorder()

        await #expect(throws: EndpointSessionError.incompleteCheckpoint) {
            try await session.generate(
                responseTo: "continue",
                onCompaction: { progress.record($0, requestCount: fixture.requests.count) },
                onChunk: { _ in }
            )
        }
        #expect(await session.exportContext() == original)
        #expect(fixture.requests.count == 1)
        #expect(await progress.states == [true, false])
    }

    @Test("A final-answer failure rolls back the successful preparatory checkpoint")
    func finalFailureRollback() async throws {
        let (session, fixture) = try makeSession(replies: [.text("Valid notes"), .status(500)])
        let original = history()
        try await session.restoreContext(original)

        await #expect(throws: EndpointSessionError.httpStatus(500)) {
            try await session.generate(responseTo: "continue", onChunk: { _ in })
        }
        #expect(await session.exportContext() == original)
        #expect(fixture.requests.count == 2)
    }

    @Test("Cancellation rolls back prepared notes and prevents concurrent context edits")
    func cancellationRollback() async throws {
        let (session, fixture) = try makeSession(replies: [.text("Valid notes"), .hold])
        let original = history()
        try await session.restoreContext(original)
        let task = Task { try await session.generate(responseTo: "continue", onChunk: { _ in }) }
        do {
            try await fixture.waitForRequests(2)
            await #expect(throws: EndpointSessionError.busy) { try await session.updateSystemPrompt("changed") }
            await #expect(throws: EndpointSessionError.busy) { try await session.restoreContext(.init()) }
            await #expect(throws: EndpointSessionError.busy) { try await session.compact() }
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await session.exportContext() == original)
        try await session.updateSystemPrompt("New instructions")
        #expect(await session.exportContext() == original)
    }

    @Test("Manual checkpoint merges existing notes, accepts guidance and keeps recent turns")
    func manualCheckpoint() async throws {
        let (session, fixture) = try makeSession(replies: [.text("Merged project decisions")])
        let original = ConversationContextState(
            turns: Array(history().turns.prefix(3)), summary: "Earlier project decision", totalOmittedTurns: 7
        )
        try await session.restoreContext(original)
        let result = try await session.compact(guidance: "Keep all file paths")
        let saved = await session.exportContext()

        #expect(fixture.requests.count == 1)
        #expect(fixture.requests[0].messages.last?.content?.contains("Earlier project decision") == true)
        #expect(fixture.requests[0].messages.last?.content?.contains("Keep all file paths") == true)
        #expect(saved.turns == Array(original.turns.suffix(1)))
        #expect(saved.summary == "Merged project decisions")
        #expect(result.totalOmittedTurns == 9)
        #expect(result.estimatedInputTokens <= result.inputBudgetTokens)
    }

    @Test("Checkpoint batches fit the input budget and carry previous notes forward")
    func boundedBatches() async throws {
        let (session, fixture) = try makeSession(
            replies: [.text("Batch one"), .text("Batch two"), .text("Batch three"), .text("Final answer")], window: 800
        )
        let original = ConversationContextState(turns: (0..<4).map {
            .init(user: "\($0)" + String(repeating: "u", count: 699), assistant: String(repeating: "a", count: 500))
        })
        try await session.restoreContext(original)
        _ = try await session.generate(responseTo: "continue", onChunk: { _ in })
        let requests = fixture.requests
        #expect(requests.count == 4)
        #expect(requests[1].messages.last?.content?.contains("Batch one") == true)
        #expect(requests[2].messages.last?.content?.contains("Batch two") == true)
        #expect(requests.allSatisfy { ApproximateTokenEstimator().estimate($0.messages) <= 672 })
        #expect(await session.exportContext().summary == "Batch three")
        #expect(await session.exportContext().turns.first == original.turns.last)
    }

    @Test("Oversized current prompt is rejected before any summary request")
    func oversizedCurrentPrompt() async throws {
        let (session, fixture) = try makeSession(replies: [])
        let original = history()
        try await session.restoreContext(original)
        await #expect(throws: ContextWindowError.self) {
            try await session.generate(responseTo: String(repeating: "x", count: 8_000), onChunk: { _ in })
        }
        #expect(fixture.requests.isEmpty)
        #expect(await session.exportContext() == original)
    }

    @Test("Restoring invalid context fails without replacing the session")
    func invalidRestore() async throws {
        let (session, _) = try makeSession(replies: [])
        let original = history()
        try await session.restoreContext(original)
        await #expect(throws: ContextWindowError.invalidSavedContext) {
            try await session.restoreContext(.init(totalOmittedTurns: -1))
        }
        #expect(await session.exportContext() == original)
    }

    private func history() -> ConversationContextState {
        .init(turns: (0..<5).map {
            .init(user: "\($0)" + String(repeating: "u", count: 399), assistant: String(repeating: "a", count: 400))
        })
    }

    private func makeSession(replies: [CheckpointReply], window: Int = 1_200) throws -> (EndpointModelSession, CheckpointFixture) {
        let fixture = CheckpointFixture(replies: replies)
        let host = "\(UUID().uuidString.lowercased()).checkpoint.test"
        CheckpointURLProtocol.fixtures.register(fixture, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckpointURLProtocol.self]
        let session = try EndpointModelSession(
            model: "test-model", endpoint: "https://\(host)/v1", maximumTokens: 128,
            contextWindowTokens: window, contextSafetyReserveTokens: 0, contextCompactAtPercent: 100,
            contextStrategy: .checkpoint, systemPrompt: "Canonical instructions",
            urlSession: URLSession(configuration: configuration)
        )
        return (session, fixture)
    }
}

@MainActor
private final class CompactionProgressRecorder {
    private(set) var states: [Bool] = []
    private(set) var requestCounts: [Int] = []

    func record(_ isCompacting: Bool, requestCount: Int) {
        states.append(isCompacting)
        requestCounts.append(requestCount)
    }
}

private enum CheckpointReply: Sendable {
    case text(String, finishReason: String = "stop")
    case status(Int)
    case hold
}

private final class CheckpointFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [CheckpointReply]
    private var captured: [ChatCompletionRequest] = []

    init(replies: [CheckpointReply]) { self.replies = replies }
    var requests: [ChatCompletionRequest] { lock.withLock { captured } }

    func receive(_ request: URLRequest) throws -> CheckpointReply {
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
        let payload = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        return lock.withLock {
            captured.append(payload)
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

private final class CheckpointFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: CheckpointFixture] = [:]
    func register(_ fixture: CheckpointFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    func fixture(for host: String) -> CheckpointFixture? { lock.withLock { fixtures[host] } }
}

private final class CheckpointURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = CheckpointFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".checkpoint.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url, let fixture = Self.fixtures.fixture(for: url.host ?? "") else { throw URLError(.badURL) }
            let reply = try fixture.receive(request)
            let status: Int
            let data: Data
            switch reply {
            case .hold: return
            case .status(let code):
                status = code
                data = Data()
            case .text(let text, let finishReason):
                status = 200
                let chunk = ChatCompletionChunk(
                    id: "checkpoint-test", model: "test-model",
                    choices: [.init(delta: .init(content: text), finishReason: finishReason)]
                )
                data = Data("data: \(String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
