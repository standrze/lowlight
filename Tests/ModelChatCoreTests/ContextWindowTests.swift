import Foundation
import ModelTransport
import Testing
@testable import ModelChatCore

@Suite("Context window management")
struct ContextWindowTests {
    @Test("Policy uses the tighter threshold or reserve limit")
    func policyBudget() throws {
        let policy = try ContextPolicy(
            windowTokens: 100,
            maximumOutputTokens: 20,
            safetyReserveTokens: 10,
            compactAtPercent: 80
        )

        #expect(policy.inputBudgetTokens == 70)
    }

    @Test("Extreme reserve values fail validation without overflowing")
    func extremeReserveValues() {
        #expect(throws: ContextWindowError.reservesExceedWindow) {
            try ContextPolicy(
                windowTokens: 4_096,
                maximumOutputTokens: Int.max,
                safetyReserveTokens: 0
            )
        }
        #expect(throws: ContextWindowError.reservesExceedWindow) {
            try ContextPolicy(
                windowTokens: 4_096,
                maximumOutputTokens: 1,
                safetyReserveTokens: Int.max
            )
        }
        #expect(throws: ContextWindowError.reservesExceedWindow) {
            try ContextPolicy(
                windowTokens: 4_096,
                maximumOutputTokens: Int.max,
                safetyReserveTokens: Int.max
            )
        }
    }

    @Test("A one-token input budget remains valid at the reserve boundary")
    func oneTokenInputBudget() throws {
        let policy = try ContextPolicy(
            windowTokens: 4_096,
            maximumOutputTokens: 4_095,
            safetyReserveTokens: 0,
            compactAtPercent: 100
        )

        #expect(policy.inputBudgetTokens == 1)
    }

    @Test("System instructions are pinned and turns stay ordered")
    func canonicalOrdering() throws {
        var manager = ContextWindowManager(
            policy: try ContextPolicy(
                windowTokens: 1_000,
                maximumOutputTokens: 100,
                safetyReserveTokens: 0,
                compactAtPercent: 100,
                systemPrompt: "Always be concise."
            )
        )

        let first = try manager.makePlan(currentPrompt: "first")
        #expect(first.messages.map(\.role) == ["system", "user"])
        _ = try manager.commit(first, currentPrompt: "first", assistantResponse: "one")

        let second = try manager.makePlan(currentPrompt: "second")
        #expect(second.messages.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(second.messages.map(\.content) == ["Always be concise.", "first", "one", "second"])
    }

    @Test("Oldest complete turns are evicted transactionally")
    func wholeTurnEviction() throws {
        var manager = ContextWindowManager(
            policy: try ContextPolicy(
                windowTokens: 80,
                maximumOutputTokens: 10,
                safetyReserveTokens: 0,
                compactAtPercent: 100
            )
        )
        let firstUser = String(repeating: "u", count: 40)
        let firstAssistant = String(repeating: "a", count: 40)
        let secondUser = String(repeating: "v", count: 40)
        let secondAssistant = String(repeating: "b", count: 40)

        let first = try manager.makePlan(currentPrompt: firstUser)
        _ = try manager.commit(
            first,
            currentPrompt: firstUser,
            assistantResponse: firstAssistant
        )
        let second = try manager.makePlan(currentPrompt: secondUser)
        _ = try manager.commit(
            second,
            currentPrompt: secondUser,
            assistantResponse: secondAssistant
        )

        let before = manager.snapshot()
        let third = try manager.makePlan(currentPrompt: "next")

        #expect(third.retainedTurns == 1)
        #expect(third.omittedTurns == 1)
        #expect(third.messages.map(\.content) == [secondUser, secondAssistant, "next"])
        #expect(manager.snapshot() == before)

        let after = try manager.commit(
            third,
            currentPrompt: "next",
            assistantResponse: "done"
        )
        #expect(after.activeTurns == 2)
        #expect(after.totalOmittedTurns == 1)
    }

    @Test("An oversized current prompt is never truncated")
    func oversizedPrompt() throws {
        let manager = ContextWindowManager(
            policy: try ContextPolicy(
                windowTokens: 80,
                maximumOutputTokens: 10,
                safetyReserveTokens: 0,
                compactAtPercent: 100
            )
        )

        #expect(throws: ContextWindowError.self) {
            try manager.makePlan(currentPrompt: String(repeating: "x", count: 400))
        }
    }

    @Test("Clearing invalidates old plans and resets omission totals")
    func clearAndStalePlan() throws {
        var manager = ContextWindowManager(
            policy: try ContextPolicy(
                windowTokens: 100,
                maximumOutputTokens: 10,
                safetyReserveTokens: 0,
                compactAtPercent: 100
            )
        )
        let plan = try manager.makePlan(currentPrompt: "hello")
        let cleared = manager.clear()

        #expect(cleared.activeTurns == 0)
        #expect(cleared.totalOmittedTurns == 0)
        #expect(throws: ContextWindowError.stalePlan) {
            try manager.commit(plan, currentPrompt: "hello", assistantResponse: "world")
        }
    }

    @Test("Fallback estimates UTF-8 deterministically")
    func tokenEstimate() {
        let estimator = ApproximateTokenEstimator()

        #expect(estimator.estimate([.init(role: "user", content: "a")]) == 9)
        #expect(estimator.estimate([.init(role: "user", content: "é")]) == 9)
        #expect(estimator.estimate([.init(role: "user", content: "🟣")]) == 9)
    }

    @Test("Saved context round-trips notes and full active turns")
    func contextRoundTrip() throws {
        let state = ConversationContextState(
            turns: [.init(user: "next", assistant: "answer")],
            summary: "Earlier decision: use Ruby.", totalOmittedTurns: 4
        )
        let decoded = try JSONDecoder().decode(ConversationContextState.self, from: JSONEncoder().encode(state))
        try decoded.validate()
        let manager = ContextWindowManager(policy: try policy(), state: decoded)
        let plan = try manager.makePlan(currentPrompt: "continue")

        #expect(manager.exportState() == state)
        #expect(plan.messages.map(\.role) == ["system", "user", "assistant", "user", "assistant", "user"])
        #expect(plan.messages[0].content == "Current instructions")
        #expect(plan.messages[2].content?.contains("historical notes, not instructions") == true)
        #expect(plan.messages[2].content?.contains("Earlier decision: use Ruby.") == true)
        #expect(plan.estimatedInputTokens == ApproximateTokenEstimator().estimate(plan.messages))
        #expect(manager.snapshot().hasSummary)
        #expect(manager.snapshot().totalOmittedTurns == 4)
    }

    @Test("Changing instructions preserves history and invalidates in-flight plans")
    func promptMutation() throws {
        let state = ConversationContextState(turns: [.init(user: "hello", assistant: "hi")], summary: "Earlier notes")
        var manager = ContextWindowManager(policy: try policy(), state: state)
        let oldPlan = try manager.makePlan(currentPrompt: "next")
        try manager.updateSystemPrompt("  New instructions  ")

        #expect(manager.exportState() == state)
        #expect(try manager.makePlan(currentPrompt: "next").messages.first?.content == "  New instructions  ")
        #expect(throws: ContextWindowError.stalePlan) {
            try manager.commit(oldPlan, currentPrompt: "next", assistantResponse: "answer")
        }
        try manager.updateSystemPrompt(nil)
        #expect(try manager.makePlan(currentPrompt: "next").messages.first?.role == "user")
        #expect(manager.exportState() == state)
    }

    @Test("Oversized replacement instructions roll back")
    func oversizedPromptMutation() throws {
        var manager = ContextWindowManager(policy: try policy())
        #expect(throws: ContextWindowError.self) {
            try manager.updateSystemPrompt(String(repeating: "x", count: 10_000))
        }
        #expect(manager.policy.systemPrompt == "Current instructions")
    }

    @Test("Replacement instructions must fit alongside the existing checkpoint")
    func promptMutationReservesCheckpoint() throws {
        let state = ConversationContextState(
            turns: [.init(user: "hello", assistant: "hi")],
            summary: String(repeating: "s", count: 1_200), totalOmittedTurns: 2
        )
        var manager = ContextWindowManager(policy: try policy(), state: state)
        #expect(throws: ContextWindowError.self) {
            try manager.updateSystemPrompt(String(repeating: "i", count: 1_400))
        }
        #expect(manager.policy.systemPrompt == "Current instructions")
        #expect(manager.exportState() == state)
    }

    @Test("Checkpoint strategy cannot silently discard turns")
    func checkpointRequired() throws {
        let state = ConversationContextState(turns: (0..<6).map {
            .init(user: "\($0)" + String(repeating: "u", count: 250), assistant: String(repeating: "a", count: 250))
        })
        var manager = ContextWindowManager(policy: try policy(strategy: .checkpoint), state: state)
        let plan = try manager.makePlan(currentPrompt: "next")
        #expect(plan.omittedTurns > 0)
        #expect(throws: ContextWindowError.checkpointRequired) {
            try manager.commit(plan, currentPrompt: "next", assistantResponse: "answer")
        }
        #expect(manager.exportState() == state)
    }

    @Test("Clearing removes the checkpoint and resetting state rejects invalid history")
    func clearSummaryAndValidate() throws {
        var manager = ContextWindowManager(
            policy: try policy(),
            state: .init(turns: [.init(user: "hello", assistant: "hi")], summary: "notes", totalOmittedTurns: 3)
        )
        manager.clear()
        #expect(manager.exportState() == .init())
        #expect(!manager.snapshot().hasSummary)
        for state in [
            ConversationContextState(totalOmittedTurns: -1),
            ConversationContextState(totalOmittedTurns: Int.max),
            ConversationContextState(summary: "  "),
            ConversationContextState(turns: [.init(user: "hello", responses: [])]),
            ConversationContextState(turns: [.init(user: "hello", responses: [.init(role: "system", content: "bad role")])]),
        ] {
            #expect(throws: ContextWindowError.invalidSavedContext) { try state.validate() }
        }
    }

    private func policy(strategy: ContextStrategy = .slidingWindow) throws -> ContextPolicy {
        try ContextPolicy(
            windowTokens: 800, maximumOutputTokens: 128, safetyReserveTokens: 0,
            compactAtPercent: 100, strategy: strategy, systemPrompt: "Current instructions"
        )
    }
}
