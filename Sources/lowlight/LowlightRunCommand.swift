import Foundation
import ModelChatCore
import ModelTransport
import SwiftTUI

private struct LowlightRunUsage: Encodable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

private struct LowlightRunOutput: Encodable {
    let answer: String
    let model: String
    let usage: LowlightRunUsage
}

@MainActor
private final class LowlightRunCollector {
    var answer = ""
    func append(_ chunk: String) { answer += chunk }
}

struct LowlightRunCommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Send one stdin prompt without starting the terminal UI."
    )

    @Option(name: .shortAndLong, help: "Model name exposed by the endpoint")
    var model: String

    @Option(name: .shortAndLong, help: "OpenAI-compatible base URL")
    var endpoint: String

    @Option(name: .long, help: "Chat API: auto, responses, or chat-completions")
    var api = OpenAIAPI.chatCompletions.rawValue

    @Option(name: .long, help: "Maximum tokens generated in the response")
    var maxTokens = 512

    @Option(name: .long, help: "Reasoning effort: low, medium, or high")
    var effort: String?

    @Option(name: .long, help: "Fallback context-window size")
    var contextWindow = 262_144

    @Option(name: .long, help: "Read system instructions from a UTF-8 file")
    var systemPromptFile: String?

    @Option(name: .long, help: "Output format; currently json")
    var output = "json"

    mutating func run() async throws {
        guard output == "json" else {
            throw ValidationError("--output must be json")
        }
        guard let selectedAPI = OpenAIAPI(rawValue: api) else {
            throw ValidationError("--api must be auto, responses, or chat-completions")
        }
        let selectedEffort: ReasoningEffort?
        if let effort {
            guard let parsed = ReasoningEffort(rawValue: effort) else {
                throw ValidationError("--effort must be low, medium, or high")
            }
            selectedEffort = parsed
        } else {
            selectedEffort = nil
        }
        guard maxTokens > 0 else { throw ValidationError("--max-tokens must be positive") }
        guard contextWindow > maxTokens + 1_024 else {
            throw ValidationError("--context-window must exceed output and safety reserves")
        }

        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw ValidationError("stdin prompt is empty") }

        let systemPrompt: String?
        if let systemPromptFile {
            let data = try Data(contentsOf: URL(fileURLWithPath: systemPromptFile))
            guard data.count <= 128 * 1_024, let decoded = String(data: data, encoding: .utf8) else {
                throw ValidationError("system prompt must be UTF-8 and at most 128 KiB")
            }
            systemPrompt = decoded
        } else {
            systemPrompt = nil
        }

        let session = try EndpointModelSession(
            model: model,
            endpoint: endpoint,
            api: selectedAPI,
            maximumTokens: maxTokens,
            contextWindowTokens: contextWindow,
            systemPrompt: systemPrompt
        )
        let collector = LowlightRunCollector()
        _ = try await session.generate(responseTo: input, reasoningEffort: selectedEffort) { chunk in
            collector.append(chunk)
        }
        let answer = await collector.answer
        guard !answer.isEmpty else { throw ValidationError("model returned no answer text") }
        let snapshot = await session.usageSnapshot()
        await session.shutdown()

        let encoded = try JSONEncoder().encode(LowlightRunOutput(
            answer: answer,
            model: model,
            usage: LowlightRunUsage(
                promptTokens: snapshot.promptTokens,
                completionTokens: snapshot.completionTokens,
                totalTokens: snapshot.totalTokens
            )
        ))
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
