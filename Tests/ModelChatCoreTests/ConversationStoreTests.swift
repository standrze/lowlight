import Foundation
import Testing
@testable import ModelChatCore

private func withConversationStore(
    _ body: (ConversationStore) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("model-chat-session-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(ConversationStore(directory: directory))
}

private func savedConversation(
    id: UUID = UUID(),
    title: String = "Saved test",
    updatedAt: Date = Date(timeIntervalSince1970: 2_000)
) -> SavedConversation {
    SavedConversation(
        id: id,
        title: title,
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: updatedAt,
        model: "test-model",
        endpoint: "http://localhost:8080/v1",
        workspacePath: "/tmp/test-workspace"
    )
}

@Test
func savedConversationRoundTripsPromptSkillsContextAndTranscript() throws {
    try withConversationStore { store in
        var expected = savedConversation()
        expected.systemPrompt = "Use concise answers."
        expected.activeSkills = [SkillDocument(
            name: "editing",
            description: "Edit prose",
            body: "Keep the author's meaning.",
            sourcePath: "/tmp/unavailable/SKILL.md"
        )]
        expected.context = ConversationContextState(
            turns: [ConversationTurn(user: "Hello", assistant: "Hi")],
            summary: "We chose a short title.",
            totalOmittedTurns: 3
        )
        let responseID = expected.transcript.beginTurn(prompt: "Hello")
        expected.transcript.append("Hi", to: responseID)
        expected.transcript.finish(responseID: responseID)
        expected.transcript.addNotice("Local notice")
        expected.inputHistory = ["Hello", "/system show"]

        let url = try store.save(expected)
        let resumed = try store.load(expected.id.uuidString)

        #expect(resumed == expected)
        #expect(url.deletingLastPathComponent() == store.directory)
        #expect(url.lastPathComponent == "\(expected.id.uuidString).json")
        #expect(try store.warnings().isEmpty)
    }
}

@Test
func anUnconnectedDraftRoundTripsWithoutInventingAModel() throws {
    try withConversationStore { store in
        var expected = savedConversation()
        expected.model = ""
        expected.draft = "Keep this draft while I choose a model."
        expected.transcript.addNotice("Choose a model before sending.")

        let url = try store.save(expected)
        let resumed = try store.load(expected.id.uuidString)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])

        #expect(resumed == expected)
        #expect(resumed.model.isEmpty)
        #expect(json["model"] as? String == "")
        #expect(try store.list().first?.model == "")
        #expect(try store.warnings().isEmpty)
    }
}

@Test(arguments: [ChatRole.user, .assistant])
func aTranscriptMessageRequiresAModelEvenWithoutCompletedContext(role: ChatRole) throws {
    try withConversationStore { store in
        var conversation = savedConversation()
        conversation.model = ""
        conversation.draft = "An unsent draft does not make earlier turns model-less."
        conversation.transcript = ChatTranscript(messages: [
            ChatMessage(role: role, text: "A previous conversation message")
        ])

        #expect(throws: ConversationStoreError.self) {
            try store.save(conversation)
        }
        let saved = try store.list()
        #expect(saved.isEmpty)
    }
}

@Test
func savedModelContextRequiresAModelEvenWithOnlyLocalNotices() throws {
    try withConversationStore { store in
        let previousContexts = [
            ConversationContextState(turns: [ConversationTurn(user: "Hello", assistant: "Hi")]),
            ConversationContextState(summary: "Earlier conversation summary"),
            ConversationContextState(totalOmittedTurns: 1)
        ]
        for context in previousContexts {
            var conversation = savedConversation()
            conversation.model = ""
            conversation.context = context
            conversation.transcript.addNotice("Local notice")

            #expect(throws: ConversationStoreError.self) {
                try store.save(conversation)
            }
        }
        let saved = try store.list()
        #expect(saved.isEmpty)
    }
}

@Test
func resumingAnInterruptedResponseKeepsPartialTextOutOfCompletedContext() throws {
    try withConversationStore { store in
        var conversation = savedConversation()
        conversation.context = ConversationContextState(
            turns: [ConversationTurn(user: "First", assistant: "Complete")]
        )
        let responseID = conversation.transcript.beginTurn(prompt: "Interrupted")
        conversation.transcript.append("Partial response", to: responseID)
        let url = try store.save(conversation)
        let originalData = try Data(contentsOf: url)

        let resumed = try store.load("last")

        #expect(resumed.transcript.messages.last?.state == .stopped)
        #expect(resumed.transcript.messages.last?.text == "Partial response")
        #expect(resumed.context == conversation.context)
        #expect(try Data(contentsOf: url) == originalData)
    }
}

@Test
func emptyInterruptedResponseBecomesAVisibleStoppedMessage() throws {
    try withConversationStore { store in
        var conversation = savedConversation()
        _ = conversation.transcript.beginTurn(prompt: "Interrupted before first token")
        try store.save(conversation)

        let resumed = try store.load("last")

        #expect(resumed.transcript.messages.last?.state == .stopped)
        #expect(resumed.transcript.messages.last?.text == "Generation stopped.")
        #expect(resumed.context.turns.isEmpty)
    }
}

@Test
func malformedAndFutureSessionsDoNotHideValidSavedConversations() throws {
    try withConversationStore { store in
        let older = savedConversation(updatedAt: Date(timeIntervalSince1970: 2_000))
        let newer = savedConversation(updatedAt: Date(timeIntervalSince1970: 3_000))
        try store.save(older)
        try store.save(newer)
        let malformedURL = store.directory.appendingPathComponent("\(UUID().uuidString).json")
        let futureID = UUID()
        let futureURL = store.directory.appendingPathComponent("\(futureID.uuidString).json")
        try Data("{broken".utf8).write(to: malformedURL)
        let futureData = Data("{\"schemaVersion\":999}".utf8)
        try futureData.write(to: futureURL)

        #expect(try store.list().map(\.id) == [newer.id, older.id])
        #expect(try store.load("last").id == newer.id)
        #expect(try store.warnings().count == 2)
        #expect(throws: ConversationStoreError.unsupportedVersion(999)) {
            try store.load(futureID.uuidString)
        }

        let wouldReplace = savedConversation(id: futureID)
        #expect(throws: ConversationStoreError.wouldOverwriteInvalidRecord(futureURL.lastPathComponent)) {
            try store.save(wouldReplace)
        }
        #expect(try Data(contentsOf: futureURL) == futureData)
    }
}

@Test
func conversationSelectorsRequireAnUnambiguousUUIDPrefix() throws {
    try withConversationStore { store in
        let first = savedConversation(id: try #require(UUID(uuidString: "12345678-0000-4000-8000-000000000001")))
        let second = savedConversation(id: try #require(UUID(uuidString: "12345678-0000-4000-8000-000000000002")))
        let third = savedConversation(id: try #require(UUID(uuidString: "abcdef12-0000-4000-8000-000000000003")))
        try store.save(first)
        try store.save(second)
        try store.save(third)

        #expect(try store.load("ABCDEF12").id == third.id)
        #expect(try store.load(second.id.uuidString.lowercased()).id == second.id)
        #expect(throws: ConversationStoreError.ambiguousSelector("12345678")) {
            try store.load("12345678")
        }
        #expect(throws: ConversationStoreError.notFound("0000")) {
            try store.load("0000")
        }
    }
}

@Test
func selectorsAndTitlesCannotEscapeTheSessionDirectory() throws {
    try withConversationStore { store in
        let conversation = savedConversation(title: "../../outside.json")
        let url = try store.save(conversation)

        #expect(url.deletingLastPathComponent() == store.directory)
        #expect(try store.load(conversation.id.uuidString).title == "../../outside.json")
        for selector in ["../outside", "/tmp/outside.json", "last/../", "", "all"] {
            #expect(throws: ConversationStoreError.invalidSelector) {
                try store.load(selector)
            }
        }
    }
}

@Test
func invalidSnapshotCannotReplaceTheLastSuccessfulSave() throws {
    try withConversationStore { store in
        let original = savedConversation()
        let url = try store.save(original)
        let originalData = try Data(contentsOf: url)
        var invalid = original
        invalid.contextSafetyReserveTokens = Int.max

        #expect(throws: ContextWindowError.reservesExceedWindow) {
            try store.save(invalid)
        }
        #expect(try Data(contentsOf: url) == originalData)
        #expect(try store.load("last") == original)
    }
}

@Test
func sessionIdentifiersMustMatchFilenamesAndLinksAreRejected() throws {
    try withConversationStore { store in
        let original = savedConversation()
        let originalURL = try store.save(original)
        let differentID = UUID()
        let differentURL = store.directory.appendingPathComponent("\(differentID.uuidString).json")
        try FileManager.default.copyItem(at: originalURL, to: differentURL)
        let linkID = UUID()
        let linkURL = store.directory.appendingPathComponent("\(linkID.uuidString).json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: originalURL)
        let originalData = try Data(contentsOf: originalURL)

        #expect(try store.list().map(\.id) == [original.id])
        #expect(try store.warnings().count == 2)
        #expect(throws: (any Error).self) { try store.load(differentID.uuidString) }
        #expect(throws: (any Error).self) { try store.load(linkID.uuidString) }
        #expect(throws: ConversationStoreError.wouldOverwriteInvalidRecord(linkURL.lastPathComponent)) {
            try store.save(savedConversation(id: linkID))
        }
        #expect(try Data(contentsOf: originalURL) == originalData)
    }
}

@Test
func endpointCredentialsAreNotWrittenToSessionFiles() throws {
    try withConversationStore { store in
        var conversation = savedConversation()
        conversation.endpoint = "https://private-user:private-password@example.com/v1?api_key=private-key#private-fragment"
        let url = try store.save(conversation)
        let json = try String(contentsOf: url, encoding: .utf8)

        #expect(!json.contains("private-user"))
        #expect(!json.contains("private-password"))
        #expect(!json.contains("private-key"))
        #expect(!json.contains("private-fragment"))
        #expect(try store.load("last").endpoint == "https://example.com/v1")
    }
}

@Test
func aMissingSessionDirectoryIsAnEmptyLibraryUntilFirstSave() throws {
    try withConversationStore { store in
        #expect(try store.list().isEmpty)
        #expect(try store.warnings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(throws: ConversationStoreError.noConversations) { try store.load("last") }
        try store.save(savedConversation())
        #expect(try store.list().count == 1)
    }
}

@Test
func multipleSessionHomesPreferCurrentSnapshotsAndSaveResumedChatsInLowlight() throws {
    try withConversationStore { store in
        let midnight = ConversationStore(directory: store.directory.appendingPathComponent("midnight"))
        let historical = ConversationStore(directory: store.directory.appendingPathComponent("historical"))
        let lowlight = store.directory.appendingPathComponent("lowlight")
        let combined = ConversationStore(directory: lowlight, fallbackDirectories: [midnight.directory, historical.directory])
        var recent = savedConversation(title: "Midnight version")
        recent.draft = "Keep this unsent draft"
        recent.archived = true
        var obsolete = recent
        obsolete.title = "Historical version"
        try historical.save(obsolete)
        let oldURL = try midnight.save(recent)
        let oldBytes = try Data(contentsOf: oldURL)
        let historicalOnly = savedConversation(title: "Historical only")
        try historical.save(historicalOnly)

        #expect(try combined.load(recent.id.uuidString) == recent)
        #expect(try combined.load(historicalOnly.id.uuidString) == historicalOnly)
        #expect(try combined.list().map(\.id) == [historicalOnly.id])
        #expect(try combined.list(includeArchived: true).count == 2)
        #expect(try ConversationStore(directory: lowlight).list(includeArchived: true).isEmpty)

        recent.title = "Saved in lowlight"
        let newURL = try combined.save(recent)
        #expect(newURL.deletingLastPathComponent().path == lowlight.standardizedFileURL.path)
        #expect(try combined.load(recent.id.uuidString) == recent)
        #expect(try Data(contentsOf: oldURL) == oldBytes)

        // An invalid current record must stay visible as a warning, never be
        // silently replaced by a stale but valid snapshot from another home.
        try Data("broken".utf8).write(to: newURL)
        #expect(throws: (any Error).self) { try combined.load(recent.id.uuidString) }
        #expect(try combined.warnings().count == 1)
    }
}

@Test
func deletionMarkersRespectPrecedenceAcrossAllSessionHomes() throws {
    try withConversationStore { store in
        let midnight = ConversationStore(directory: store.directory.appendingPathComponent("midnight"))
        let historical = ConversationStore(directory: store.directory.appendingPathComponent("historical"))
        let lowlight = store.directory.appendingPathComponent("lowlight")
        let combined = ConversationStore(directory: lowlight, fallbackDirectories: [midnight.directory, historical.directory])
        let deletedInMidnight = savedConversation()
        let deletedInLowlight = savedConversation()
        let currentSnapshot = savedConversation()
        for saved in [deletedInMidnight, deletedInLowlight, currentSnapshot] {
            try historical.save(saved)
            try midnight.save(saved)
        }
        try midnight.delete(deletedInMidnight.id.uuidString)
        try combined.save(currentSnapshot)
        try midnight.delete(currentSnapshot.id.uuidString)
        try combined.delete(deletedInLowlight.id.uuidString)

        #expect(try combined.list(includeArchived: true).map(\.id) == [currentSnapshot.id])
        for saved in [deletedInMidnight, deletedInLowlight] {
            #expect(throws: (any Error).self) { try combined.load(saved.id.uuidString) }
            #expect(try historical.load(saved.id.uuidString) == saved)
        }
        #expect(try ConversationStore(directory: lowlight.appendingPathComponent(".trash")).load("last").id == deletedInLowlight.id)
    }
}
