import Foundation

public struct TranscriptTurn: Identifiable, Equatable, Sendable {
    public let number: Int
    public let user: ChatMessage
    public let response: ChatMessage?
    public let startIndex: Int
    public let endIndex: Int
    public var id: Int { number }
}

extension ChatTranscript {
    public var turns: [TranscriptTurn] {
        let starts = messages.indices.filter { messages[$0].role == .user }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : messages.endIndex
            return TranscriptTurn(number: offset + 1, user: messages[start],
                response: messages[(start + 1)..<end].first { $0.role == .assistant },
                startIndex: start, endIndex: end)
        }
    }

    /// Only successful pairs are eligible as model context. Never replay error/partial text or notices.
    public var completedContext: ConversationContextState {
        .init(turns: turns.compactMap { turn in
            guard let response = turn.response, response.state == .complete else { return nil }
            return ConversationTurn(user: ChatAttachment.prompt(turn.user.text, attachments: turn.user.attachments ?? []),
                                    assistant: response.text)
        })
    }

    public func search(_ query: String) -> [TranscriptTurn] {
        turns.filter {
            [$0.user.text, $0.response?.text ?? "", $0.response?.reasoning ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

extension SavedConversation {
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [title, model, workspacePath, id.uuidString, draft ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
            || transcript.messages.contains {
                $0.text.localizedCaseInsensitiveContains(query) || ($0.reasoning ?? "").localizedCaseInsensitiveContains(query)
            }
    }

    /// Without a turn, clone the exact context. At an earlier point rebuild from the prefix;
    /// an existing checkpoint might contain information from the future of that branch.
    public func branched(at turnNumber: Int? = nil, before: Bool = false) throws -> SavedConversation {
        var copy = self
        copy.id = UUID()
        copy.parentID = id
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        copy.archived = nil
        copy.title = String((title + " · branch").prefix(200))
        if let turnNumber {
            guard let turn = transcript.turns.first(where: { $0.number == turnNumber }) else {
                throw ConversationFeatureError.message("Choose a turn from 1 to \(transcript.turns.count).")
            }
            copy.transcript = ChatTranscript(messages: Array(transcript.messages.prefix(before ? turn.startIndex : turn.endIndex)))
            copy.context = copy.transcript.completedContext
            copy.draft = before ? turn.user.text : nil
            copy.pendingAttachments = before ? turn.user.attachments : nil
            copy.inputHistory = copy.transcript.turns.map(\.user.text)
        }
        return copy
    }

    /// Markdown export keeps original Markdown, attachment snapshots, and reasoning.
    public var markdown: String {
        var sections = ["# \(title)", "Model: \(model)\n\nWorkspace: \(workspacePath)"]
        for message in transcript.messages {
            sections.append("## \(message.role.rawValue.capitalized)\(message.state == .complete ? "" : " (\(message.state.rawValue))")")
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                sections.append("### Thinking\n\n" + reasoning + "\n\n### Answer")
            }
            sections.append(message.text)
            for file in message.attachments ?? [] {
                // Choose a fence longer than every backtick run in the original file.
                let longest = file.text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                sections.append("### Attached: \(file.path)\n\n\(fence)\n\(file.text)\n\(fence)")
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    public func exportMarkdown(to url: URL) throws {
        // Never silently replace a user's existing document, including a dangling link.
        try Data(markdown.utf8).write(to: url, options: .withoutOverwriting)
    }
}
