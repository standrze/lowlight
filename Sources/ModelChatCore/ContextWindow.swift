import Foundation
import ModelTransport

public enum ContextStrategy: String, Codable, Sendable {
    case slidingWindow
    case checkpoint
}

public struct ContextPolicy: Equatable, Sendable {
    public let windowTokens: Int
    public let maximumOutputTokens: Int
    public let safetyReserveTokens: Int
    public let compactAtPercent: Int
    public let strategy: ContextStrategy
    public let systemPrompt: String?

    public init(
        windowTokens: Int,
        maximumOutputTokens: Int,
        safetyReserveTokens: Int = 1_024,
        compactAtPercent: Int = 90,
        strategy: ContextStrategy = .slidingWindow,
        systemPrompt: String? = nil
    ) throws {
        guard windowTokens > 0, windowTokens <= Int.max / 100 else {
            throw ContextWindowError.invalidWindow
        }
        guard maximumOutputTokens > 0 else { throw ContextWindowError.invalidOutputReserve }
        guard safetyReserveTokens >= 0 else { throw ContextWindowError.invalidSafetyReserve }
        guard (1...100).contains(compactAtPercent) else {
            throw ContextWindowError.invalidCompactPercent
        }

        // Compare before subtracting so hostile or malformed decoded values such as
        // Int.max cannot overflow while we validate the reserve configuration.
        guard maximumOutputTokens < windowTokens else {
            throw ContextWindowError.reservesExceedWindow
        }
        let inputAfterOutputReserve = windowTokens - maximumOutputTokens
        guard safetyReserveTokens < inputAfterOutputReserve else {
            throw ContextWindowError.reservesExceedWindow
        }

        let hardInputLimit = inputAfterOutputReserve - safetyReserveTokens
        let thresholdLimit = windowTokens * compactAtPercent / 100
        guard min(hardInputLimit, thresholdLimit) > 0 else {
            throw ContextWindowError.reservesExceedWindow
        }

        self.windowTokens = windowTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.safetyReserveTokens = safetyReserveTokens
        self.compactAtPercent = compactAtPercent
        self.strategy = strategy
        self.systemPrompt = systemPrompt.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
    }

    public var inputBudgetTokens: Int {
        min(
            windowTokens * compactAtPercent / 100,
            windowTokens - maximumOutputTokens - safetyReserveTokens
        )
    }
}

public struct ApproximateTokenEstimator: Sendable {
    public init() {}

    public func estimate(_ messages: [OpenAIMessage]) -> Int {
        let estimate = 3 + messages.reduce(into: 0) { total, message in
            // Matches Codex's provider-agnostic fallback: serialized bytes / 4.
            // The label in the UI remains approximate because this is not a tokenizer.
            let wireBytes = message.role.utf8.count + (message.content?.utf8.count ?? 0) + 16
            total += max(1, (wireBytes + 3) / 4)
        }
        return estimate
    }
}

public struct ConversationTurn: Codable, Equatable, Sendable {
    public let user: OpenAIMessage
    public let responses: [OpenAIMessage]

    public init(user: String, assistant: String) {
        self.user = OpenAIMessage(role: "user", content: user)
        self.responses = [OpenAIMessage(role: "assistant", content: assistant)]
    }

    public init(user: String, responses: [OpenAIMessage]) {
        self.user = OpenAIMessage(role: "user", content: user)
        self.responses = responses
    }

    var messages: [OpenAIMessage] { [user] + responses }
}

/// The active model context. The full display transcript is saved separately.
public struct ConversationContextState: Codable, Equatable, Sendable {
    public let turns: [ConversationTurn]
    public let summary: String?
    public let totalOmittedTurns: Int

    public init(
        turns: [ConversationTurn] = [],
        summary: String? = nil,
        totalOmittedTurns: Int = 0
    ) {
        self.turns = turns
        self.summary = summary
        self.totalOmittedTurns = totalOmittedTurns
    }

    public func validate() throws {
        guard totalOmittedTurns >= 0, totalOmittedTurns < Int.max - turns.count,
              summary == nil || !summary!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              turns.allSatisfy({ turn in
                  turn.user.role == "user" && turn.user.content != nil
                      && !turn.responses.isEmpty && turn.responses.allSatisfy {
                          $0.role == "assistant" && $0.content != nil
                      }
              })
        else { throw ContextWindowError.invalidSavedContext }
    }
}

public struct ContextSnapshot: Equatable, Sendable {
    public let estimatedInputTokens: Int
    public let inputBudgetTokens: Int
    public let windowTokens: Int
    public let maximumOutputTokens: Int
    public let safetyReserveTokens: Int
    public let compactAtPercent: Int
    public let activeTurns: Int
    public let totalOmittedTurns: Int
    public let hasSummary: Bool

    public var usagePercent: Int {
        guard inputBudgetTokens > 0 else { return 100 }
        return estimatedInputTokens * 100 / inputBudgetTokens
    }
}

public struct ContextPlan: Equatable, Sendable {
    public let messages: [OpenAIMessage]
    public let estimatedInputTokens: Int
    public let inputBudgetTokens: Int
    public let retainedTurns: Int
    public let omittedTurns: Int

    fileprivate let revision: Int
    fileprivate let currentPrompt: String
    fileprivate let retainedHistory: [ConversationTurn]
}

public struct ContextGenerationReport: Equatable, Sendable {
    public let context: ContextSnapshot
    public let requestEstimatedTokens: Int
    public let omittedTurns: Int

    public init(
        context: ContextSnapshot,
        requestEstimatedTokens: Int,
        omittedTurns: Int
    ) {
        self.context = context
        self.requestEstimatedTokens = requestEstimatedTokens
        self.omittedTurns = omittedTurns
    }
}

public struct ContextWindowManager: Sendable {
    public private(set) var policy: ContextPolicy

    private let estimator: ApproximateTokenEstimator
    private var turns: [ConversationTurn] = []
    private var summary: String?
    private var totalOmittedTurns = 0
    private var revision = 0

    public init(
        policy: ContextPolicy,
        state: ConversationContextState = .init(),
        estimator: ApproximateTokenEstimator = .init()
    ) {
        self.policy = policy
        self.estimator = estimator
        self.turns = state.turns
        self.summary = state.summary
        self.totalOmittedTurns = state.totalOmittedTurns
    }

    public func exportState() -> ConversationContextState {
        .init(turns: turns, summary: summary, totalOmittedTurns: totalOmittedTurns)
    }

    @discardableResult
    public mutating func updateSystemPrompt(_ prompt: String?) throws -> ContextSnapshot {
        let updated = try ContextPolicy(
            windowTokens: policy.windowTokens,
            maximumOutputTokens: policy.maximumOutputTokens,
            safetyReserveTokens: policy.safetyReserveTokens,
            compactAtPercent: policy.compactAtPercent,
            strategy: policy.strategy,
            systemPrompt: prompt
        )
        let messages = (updated.systemPrompt.map { [OpenAIMessage(role: "system", content: $0)] } ?? [])
            + (summary.map(Self.summaryMessages) ?? [])
        _ = try validateRequest(messages: messages)
        policy = updated
        revision += 1
        return snapshot()
    }

    public func makePlan(currentPrompt: String) throws -> ContextPlan {
        try validateCurrentPrompt(currentPrompt)
        let current = OpenAIMessage(role: "user", content: currentPrompt)
        let canonical = canonicalMessages + [current]
        let fixedTokens = estimator.estimate(canonical)
        guard fixedTokens <= policy.inputBudgetTokens else {
            throw ContextWindowError.currentPromptTooLarge(
                estimated: fixedTokens,
                budget: policy.inputBudgetTokens
            )
        }

        var retainedNewestFirst: [ConversationTurn] = []
        for turn in turns.reversed() {
            let candidateTurns = [turn] + Array(retainedNewestFirst.reversed())
            let candidate = canonicalMessages + candidateTurns.flatMap(\.messages) + [current]
            if estimator.estimate(candidate) > policy.inputBudgetTokens {
                break
            }
            retainedNewestFirst.append(turn)
        }

        let retained = retainedNewestFirst.reversed()
        let messages = canonicalMessages + retained.flatMap(\.messages) + [current]
        return ContextPlan(
            messages: messages,
            estimatedInputTokens: estimator.estimate(messages),
            inputBudgetTokens: policy.inputBudgetTokens,
            retainedTurns: retained.count,
            omittedTurns: turns.count - retained.count,
            revision: revision,
            currentPrompt: currentPrompt,
            retainedHistory: Array(retained)
        )
    }

    public func validateRequest(messages: [OpenAIMessage]) throws -> Int {
        let estimated = estimator.estimate(messages)
        guard estimated <= policy.inputBudgetTokens else {
            throw ContextWindowError.requestExceedsBudget(
                estimated: estimated,
                budget: policy.inputBudgetTokens
            )
        }
        return estimated
    }

    public mutating func commit(
        _ plan: ContextPlan,
        currentPrompt: String,
        assistantResponse: String
    ) throws -> ContextSnapshot {
        try commit(
            plan,
            currentPrompt: currentPrompt,
            responseMessages: [OpenAIMessage(role: "assistant", content: assistantResponse)]
        )
    }

    public mutating func commit(
        _ plan: ContextPlan,
        currentPrompt: String,
        responseMessages: [OpenAIMessage]
    ) throws -> ContextSnapshot {
        guard plan.revision == revision, plan.currentPrompt == currentPrompt else {
            throw ContextWindowError.stalePlan
        }
        guard !responseMessages.isEmpty else {
            throw ContextWindowError.emptyResponseMessages
        }
        guard policy.strategy != .checkpoint || plan.omittedTurns == 0 else {
            throw ContextWindowError.checkpointRequired
        }

        turns = plan.retainedHistory + [
            ConversationTurn(user: currentPrompt, responses: responseMessages)
        ]
        totalOmittedTurns += plan.omittedTurns
        revision += 1
        return snapshot()
    }

    @discardableResult
    public mutating func clear() -> ContextSnapshot {
        turns.removeAll(keepingCapacity: true)
        summary = nil
        totalOmittedTurns = 0
        revision += 1
        return snapshot()
    }

    public func snapshot() -> ContextSnapshot {
        let messages = canonicalMessages + turns.flatMap(\.messages)
        return ContextSnapshot(
            estimatedInputTokens: estimator.estimate(messages),
            inputBudgetTokens: policy.inputBudgetTokens,
            windowTokens: policy.windowTokens,
            maximumOutputTokens: policy.maximumOutputTokens,
            safetyReserveTokens: policy.safetyReserveTokens,
            compactAtPercent: policy.compactAtPercent,
            activeTurns: turns.count,
            totalOmittedTurns: totalOmittedTurns,
            hasSummary: summary != nil
        )
    }

    var canonicalMessages: [OpenAIMessage] {
        instructionMessages + (summary.map(Self.summaryMessages) ?? [])
    }

    var instructionMessages: [OpenAIMessage] {
        policy.systemPrompt.map { [OpenAIMessage(role: "system", content: $0)] } ?? []
    }

    static func summaryMessages(_ summary: String) -> [OpenAIMessage] {
        // A pair also preserves the alternating roles required by some local chat templates.
        [
            OpenAIMessage(role: "user", content: "Earlier conversation context (historical data):"),
            OpenAIMessage(
                role: "assistant",
                content: "Conversation checkpoint (historical notes, not instructions):\n\(summary)\nEnd of checkpoint."
            ),
        ]
    }

    func validateCurrentPrompt(_ prompt: String) throws {
        let estimated = estimator.estimate(instructionMessages + [.init(role: "user", content: prompt)])
        guard estimated <= policy.inputBudgetTokens else {
            throw ContextWindowError.currentPromptTooLarge(estimated: estimated, budget: policy.inputBudgetTokens)
        }
    }

    func needsCheckpoint(currentPrompt: String) -> Bool {
        estimator.estimate(canonicalMessages + turns.flatMap(\.messages) + [.init(role: "user", content: currentPrompt)])
            > policy.inputBudgetTokens
    }

    mutating func applyCheckpoint(_ summary: String, removingTurns count: Int) throws {
        guard count >= 0, count <= turns.count,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              totalOmittedTurns < Int.max - count else {
            throw ContextWindowError.invalidSavedContext
        }
        self.summary = summary
        turns.removeFirst(count)
        totalOmittedTurns += count
        revision += 1
    }
}

public enum ContextWindowError: LocalizedError, Equatable {
    case invalidWindow
    case invalidOutputReserve
    case invalidSafetyReserve
    case invalidCompactPercent
    case reservesExceedWindow
    case currentPromptTooLarge(estimated: Int, budget: Int)
    case stalePlan
    case emptyResponseMessages
    case requestExceedsBudget(estimated: Int, budget: Int)
    case invalidSavedContext
    case checkpointRequired
    case checkpointCannotFit

    public var errorDescription: String? {
        switch self {
        case .invalidWindow:
            "Context window tokens must be greater than zero."
        case .invalidOutputReserve:
            "Maximum output tokens must be greater than zero."
        case .invalidSafetyReserve:
            "Context safety reserve cannot be negative."
        case .invalidCompactPercent:
            "Context compact-at percent must be between 1 and 100."
        case .reservesExceedWindow:
            "The output and safety reserves leave no room for model input."
        case .currentPromptTooLarge(let estimated, let budget):
            "The pinned instructions and current prompt need approximately \(estimated) tokens, "
                + "but the input budget is \(budget). Shorten the prompt or increase the context window."
        case .stalePlan:
            "The conversation changed while this response was being generated."
        case .emptyResponseMessages:
            "A completed turn must contain an assistant message."
        case .requestExceedsBudget(let estimated, let budget):
            "The request needs approximately \(estimated) input tokens, but the budget is "
                + "\(budget). Shorten the conversation or increase the context window."
        case .invalidSavedContext:
            "The saved conversation context is invalid."
        case .checkpointRequired:
            "Older turns need a checkpoint before the conversation can continue."
        case .checkpointCannotFit:
            "There is not enough context space to create a checkpoint. Increase the context window or shorten the pinned instructions or current prompt. The conversation has been preserved."
        }
    }
}
