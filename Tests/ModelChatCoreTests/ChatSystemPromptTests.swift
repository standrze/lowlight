import Testing
@testable import ModelChatCore

@Test
func chatPresentationDefaultsPreserveExplicitInstructionsAndSkills() throws {
    let base = "  Use the exact Unicode test data: 1️⃣ 😀 **literal**.\n"
    let skill = SkillDocument(
        name: "examples",
        description: "Metadata stays out of the request.",
        body: "Keep all numeric literals and string contents unchanged.",
        sourcePath: "/tmp/examples/SKILL.md"
    )
    let originalInstructions = try #require(composeSystemPrompt(base: base, skills: [skill]))
    let composed = ChatSystemPrompt.compose(base: base, skills: [skill])

    #expect(composed.hasPrefix(ChatSystemPrompt.codePresentationDefaults + "\n\n"))
    #expect(composed.hasSuffix(originalInstructions))
    #expect(composed.contains(base))
    #expect(!composed.contains(skill.description))
    #expect(!composed.contains(skill.sourcePath))
    #expect(ChatSystemPrompt.compose(base: nil, skills: []) == ChatSystemPrompt.codePresentationDefaults)
    #expect(ChatSystemPrompt.compose(base: "", skills: []) == ChatSystemPrompt.codePresentationDefaults)
}

@Test
func resumedHistoryAndInstructionEditsKeepCodeDefaultsWithoutRewritingPreviousAnswers() throws {
    let previousCode = "let sample = \"1️⃣ 😀 **literal**\"\nlet count = 2 + 1"
    let state = ConversationContextState(turns: [
        ConversationTurn(user: "Show the exact test data", assistant: previousCode)
    ])
    var manager = ContextWindowManager(
        policy: try ContextPolicy(
            windowTokens: 8_192,
            maximumOutputTokens: 512,
            systemPrompt: ChatSystemPrompt.compose(base: "Original instructions", skills: [])
        ),
        state: state
    )
    let resumed = try manager.makePlan(currentPrompt: "Continue")
    #expect(resumed.messages.first?.role == "system")
    #expect(resumed.messages.first?.content?.hasPrefix(ChatSystemPrompt.codePresentationDefaults) == true)
    #expect(resumed.messages.first(where: { $0.role == "assistant" })?.content == previousCode)

    let edited = "Use Unicode examples when I request them."
    try manager.updateSystemPrompt(ChatSystemPrompt.compose(base: edited, skills: []))
    let updated = try manager.makePlan(currentPrompt: "Continue")
    #expect(updated.messages.first?.content == ChatSystemPrompt.codePresentationDefaults + "\n\n" + edited)
    #expect(updated.messages.first(where: { $0.role == "assistant" })?.content == previousCode)
    #expect(manager.exportState() == state)

    try manager.updateSystemPrompt(ChatSystemPrompt.compose(base: nil, skills: []))
    #expect(try manager.makePlan(currentPrompt: "Continue").messages.first?.content == ChatSystemPrompt.codePresentationDefaults)
    #expect(manager.exportState() == state)
}

@Test
func fencedCodePreservesRequiredSymbolsAndMarkdownLookingStringData() {
    let code = """
        let sample = "1️⃣ 😀 **literal**"
        let count = 2 + 1
        let comparison = count <= 4 && count != 0
        // Existing comment → kept verbatim.
        """
    let spans = ChatMarkdown.spans("```swift\n" + code + "\n```")

    #expect(spans.map(\.text).joined() == code + "\n")
    #expect(spans.allSatisfy { $0.code && !$0.bold && !$0.italic })
}
