import Foundation
import Testing
import ModelTransport
@testable import ModelChatCore

private func featureDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("midnight-features-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func featureConversation() -> SavedConversation {
    .init(title: "Review notes", model: "test", endpoint: "http://localhost:8080/v1", workspacePath: "/tmp")
}

@Test func attachmentSnapshotSurvivesSourceChangeAndHandlesSpaces() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("my notes.txt")
    try Data("first version\n".utf8).write(to: file)
    let attachment = try ChatAttachment.read("\"my notes.txt\"", workspace: dir)
    try Data("second version".utf8).write(to: file)
    let prompt = ChatAttachment.prompt("Summarize", attachments: [attachment])
    #expect(attachment.path == file.path)
    #expect(prompt.contains("first version"))
    #expect(!prompt.contains("second version"))
    #expect(attachment.estimatedTokens > 0)
    #expect(ChatAttachment.prompt("Plain", attachments: []) == "Plain")
}

@Test func attachmentsRejectBinaryControlsDirectoriesOversizeAndDuplicates() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("test.txt")
    for bytes in [Data([0xFF]), Data([0]), Data("\u{1B}[31m".utf8), Data(repeating: 65, count: ChatAttachment.maximumBytes + 1)] {
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try ChatAttachment.read(file.path, workspace: dir) }
    }
    #expect(throws: (any Error).self) { try ChatAttachment.read(dir.path, workspace: dir) }
    let attachment = ChatAttachment(path: file.path, text: "safe\n\ttext")
    #expect(throws: (any Error).self) { try ChatAttachment.validate([attachment, attachment]) }
    let large = (0..<5).map { ChatAttachment(path: "/tmp/file\($0)", text: String(repeating: "a", count: ChatAttachment.maximumBytes)) }
    #expect(throws: (any Error).self) { try ChatAttachment.validate(large) }
}

@Test func draftOnlySessionRestoresAndCanBeClearedWithoutLosingAttachments() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ConversationStore(directory: dir)
    var saved = featureConversation()
    saved.draft = "Unsent\nsecond line"
    saved.pendingAttachments = [.init(path: "/tmp/missing-now.txt", text: "snapshot")]
    saved.apiKeyEnvironment = "LOCAL_MODEL_KEY"
    try store.save(saved)
    let restored = try store.load("last")
    #expect(restored.draft == saved.draft)
    #expect(restored.pendingAttachments == saved.pendingAttachments)
    #expect(restored.apiKeyEnvironment == "LOCAL_MODEL_KEY")
    #expect(try store.list().first?.hasDraft == true)
    saved.draft = nil; saved.pendingAttachments = nil
    try store.save(saved)
    #expect(try store.load("last").draft == nil)
    #expect(try store.list().first?.hasDraft == false)
}

@Test func legacySessionWithoutNewFieldsStillLoads() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ConversationStore(directory: dir)
    let saved = featureConversation()
    let url = try store.save(saved)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    for field in ["draft", "pendingAttachments", "archived", "parentID", "apiKeyEnvironment"] { json.removeValue(forKey: field) }
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let restored = try store.load("last")
    #expect(restored.draft == nil)
    #expect(restored.pendingAttachments == nil)
    #expect(restored.archived == nil)
    #expect(restored.transcript.messages.isEmpty)
}

@Test func editingEarlierTurnDoesNotLeakFutureCheckpointOrFailures() throws {
    var saved = featureConversation()
    let file = ChatAttachment(path: "/tmp/first.txt", text: "file content")
    let first = saved.transcript.beginTurn(prompt: "First", attachments: [file])
    saved.transcript.append("First answer", to: first); saved.transcript.finish(responseID: first)
    saved.transcript.addNotice("Do not include local notices")
    let failed = saved.transcript.beginTurn(prompt: "Failed user")
    saved.transcript.fail(responseID: failed, description: "Do not include server errors")
    let third = saved.transcript.beginTurn(prompt: "Third", attachments: [file])
    saved.transcript.append("Future answer", to: third); saved.transcript.finish(responseID: third)
    saved.context = .init(turns: [.init(user: "Third", assistant: "Future answer")], summary: "Future private decisions", totalOmittedTurns: 2)
    let branch = try saved.branched(at: 3, before: true)
    #expect(branch.id != saved.id)
    #expect(branch.parentID == saved.id)
    #expect(branch.draft == "Third")
    #expect(branch.pendingAttachments == [file])
    #expect(branch.context.summary == nil)
    #expect(branch.context.totalOmittedTurns == 0)
    #expect(branch.context.turns.count == 1)
    #expect(branch.context.turns[0].user.content?.contains("file content") == true)
    #expect(!String(describing: branch.context).contains("Future"))
    #expect(branch.transcript.turns.count == 2)
    #expect(saved.transcript.turns.count == 3)
}

@Test func branchAtFirstStartsEmptyAndFullBranchKeepsExactContext() throws {
    var saved = featureConversation()
    let id = saved.transcript.beginTurn(prompt: "Hello")
    saved.transcript.append("Hi", to: id); saved.transcript.finish(responseID: id)
    saved.context = .init(turns: [.init(user: "Hello", assistant: "Hi")], summary: "Earlier summary", totalOmittedTurns: 2)
    let first = try saved.branched(at: 1, before: true)
    #expect(first.context == .init())
    #expect(first.transcript.messages.isEmpty)
    #expect(first.draft == "Hello")
    let full = try saved.branched()
    #expect(full.context == saved.context)
    #expect(full.transcript == saved.transcript)
    let through = try saved.branched(at: 1)
    #expect(through.context.turns.count == 1)
    #expect(through.draft == nil)
    #expect(throws: (any Error).self) { try saved.branched(at: 0) }
    #expect(throws: (any Error).self) { try saved.branched(at: 2) }
}

@Test func failedAndStoppedTurnsRemainRetryableButNeverEnterContext() throws {
    var saved = featureConversation()
    let stopped = saved.transcript.beginTurn(prompt: "Retry this")
    saved.transcript.appendReasoning("Partial thinking", to: stopped)
    saved.transcript.append("Partial text", to: stopped); saved.transcript.stop(responseID: stopped)
    let branch = try saved.branched(at: 1, before: true)
    #expect(branch.draft == "Retry this")
    #expect(saved.transcript.completedContext.turns.isEmpty)
    #expect(branch.context.turns.isEmpty)
}

@Test func sessionsSearchTranscriptDraftAndMetadataCaseInsensitively() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ConversationStore(directory: dir)
    var saved = featureConversation()
    saved.draft = "Unsent zebra"
    let response = saved.transcript.beginTurn(prompt: "Question")
    saved.transcript.append("Needle in a long answer", to: response)
    saved.transcript.appendReasoning("Consider the lighthouse", to: response)
    saved.transcript.finish(responseID: response)
    try store.save(saved)
    for query in ["REVIEW", "needle", "zebra", "lighthouse"] {
        #expect(try store.list(query: query).count == 1)
    }
    #expect(try store.list(query: "absent").isEmpty)
    #expect(saved.transcript.search("NEEDLE").first?.number == 1)
}

@Test func archiveRestoreAndDeletionDoNotResurrectLegacySessions() throws {
    let root = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    let current = root.appendingPathComponent("current")
    let saved = featureConversation()
    try ConversationStore(directory: legacy).save(saved)
    let store = ConversationStore(directory: current, fallbackDirectory: legacy)
    try store.setArchived(saved.id.uuidString, archived: true)
    #expect(try store.list().isEmpty)
    #expect(try store.list(includeArchived: true).first?.archived == true)
    #expect(throws: ConversationStoreError.noConversations) { try store.load("last") }
    try store.setArchived(saved.id.uuidString, archived: false)
    #expect(try store.list().count == 1)
    try store.delete(saved.id.uuidString)
    #expect(try store.list(includeArchived: true).isEmpty)
    #expect(throws: (any Error).self) { try store.load(saved.id.uuidString) }
    #expect(try ConversationStore(directory: legacy).load("last").id == saved.id)
    #expect(try ConversationStore(directory: current.appendingPathComponent(".trash")).load("last").id == saved.id)
}

@Test func exportPreservesReasoningCodeAndAttachmentsAndRefusesOverwrite() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var saved = featureConversation()
    let response = saved.transcript.beginTurn(prompt: "Question", attachments: [.init(path: "/tmp/a.txt", text: "```ruby\nputs 1\n```")])
    saved.transcript.append("**Answer**", to: response)
    saved.transcript.appendReasoning("Thinking text", to: response)
    saved.transcript.finish(responseID: response)
    let url = dir.appendingPathComponent("export.md")
    try saved.exportMarkdown(to: url)
    let result = try String(contentsOf: url, encoding: .utf8)
    #expect(result.contains("**Answer**"))
    #expect(result.contains("Thinking text"))
    #expect(result.contains("````\n```ruby"))
    #expect(throws: (any Error).self) { try saved.exportMarkdown(to: url) }
    #expect(try String(contentsOf: url, encoding: .utf8) == result)
}

@Test func namedProfilesRoundTripSettingsWithoutCredentials() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ConnectionProfileStore(directory: dir)
    let profile = ConnectionProfile(name: "local", endpoint: "http://127.0.0.1:8081/v1", model: "test", apiKeyEnvironment: "LOCAL_MODEL_KEY", reasoningEffort: .high)
    try store.save(profile)
    #expect(try store.load("local") == profile)
    #expect(try store.list().profiles.count == 1)
    let data = try String(contentsOf: dir.appendingPathComponent("local.json"), encoding: .utf8)
    #expect(data.contains("LOCAL_MODEL_KEY"))
    #expect(!data.contains("apiKey\""))
    var bad = profile
    bad.endpoint = "https://user:secret@example.com/v1"
    #expect(throws: (any Error).self) { try store.save(bad) }
    bad = profile; bad.name = "../escape"
    #expect(throws: (any Error).self) { try store.save(bad) }
    bad = profile; bad.apiKeyEnvironment = "sk-secret-value"
    #expect(throws: (any Error).self) { try store.save(bad) }
    #expect(try store.load("local") == profile)
}

@Test func corruptProfileDoesNotHideHealthyProfilesOrGetOverwritten() throws {
    let dir = try featureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ConnectionProfileStore(directory: dir)
    let profile = ConnectionProfile(name: "valid", endpoint: "http://localhost:8080/v1", model: "test")
    try store.save(profile)
    let corrupt = dir.appendingPathComponent("broken.json")
    try Data("broken".utf8).write(to: corrupt)
    #expect(try store.list().profiles.count == 1)
    #expect(try store.list().warnings.count == 1)
    var replacement = profile; replacement.name = "broken"
    #expect(throws: (any Error).self) { try store.save(replacement) }
    #expect(try String(contentsOf: corrupt, encoding: .utf8) == "broken")
}

@Test func modelCapabilitiesRemainUnknownUnlessAdvertisedAndValidateKnownLimits() throws {
    let decoder = JSONDecoder()
    let unknown = try decoder.decode(OpenAIModel.self, from: Data(#"{"id":"test"}"#.utf8))
    #expect(unknown.contextWindow == nil)
    #expect(unknown.supportedReasoningEfforts == nil)
    #expect(unknown.settingIssues(contextWindow: 32_768, effort: .high).isEmpty)
    let known = try decoder.decode(OpenAIModel.self, from: Data(#"{"id":"test","context_length":4096,"supported_reasoning_efforts":["low"]}"#.utf8))
    #expect(known.contextWindow == 4096)
    #expect(known.settingIssues(contextWindow: 8192, effort: .high).count == 2)
    #expect(known.settingIssues(contextWindow: 4096, effort: .low).isEmpty)
    #expect(known.settingIssues(contextWindow: 4096, effort: nil).isEmpty)
    let noEffort = OpenAIModel(id: "test", supportedReasoningEfforts: [])
    #expect(noEffort.settingIssues(contextWindow: 4096, effort: .low).count == 1)
    #expect(try decoder.decode(OpenAIModel.self, from: JSONEncoder().encode(known)) == known)
}

@Test func connectionErrorsIncludeSpecificRecoverySteps() {
    let authentication = ConnectionDiagnostics.describe(EndpointSessionError.httpStatus(401), endpoint: "http://localhost/v1", apiKeyEnvironment: "LOCAL_KEY")
    #expect(authentication.contains("LOCAL_KEY"))
    #expect(authentication.contains("authentication"))
    let refused = ConnectionDiagnostics.describe(URLError(.cannotConnectToHost), endpoint: "http://localhost/v1", apiKeyEnvironment: "LOCAL_KEY")
    #expect(refused.contains("server is running"))
}
