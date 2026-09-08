import Foundation

public enum ChatRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case notice
}

public enum ChatMessageState: String, Codable, Equatable, Sendable {
    case complete
    case streaming
    case stopped
    case failed
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public private(set) var text: String
    public private(set) var reasoning: String?
    public let attachments: [ChatAttachment]?
    public private(set) var state: ChatMessageState

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        state: ChatMessageState = .complete,
        reasoning: String? = nil,
        attachments: [ChatAttachment]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
        self.reasoning = reasoning
        self.attachments = attachments
    }

    mutating func append(_ chunk: String) {
        text += chunk
    }

    mutating func appendReasoning(_ chunk: String) {
        reasoning = (reasoning ?? "") + chunk
    }

    mutating func finish() {
        state = .complete
    }

    mutating func stop() {
        state = .stopped
        if text.isEmpty {
            text = "Generation stopped."
        }
    }

    mutating func fail(with description: String) {
        state = .failed
        let errorLine = "Error: \(description)"
        text = text.isEmpty ? errorLine : "\(text)\n\n\(errorLine)"
    }
}

public struct ChatTranscript: Codable, Equatable, Sendable {
    public private(set) var messages: [ChatMessage]

    public init(messages: [ChatMessage] = []) {
        self.messages = messages
    }

    @discardableResult
    public mutating func beginTurn(prompt: String, attachments: [ChatAttachment] = []) -> UUID {
        messages.append(ChatMessage(role: .user, text: prompt, attachments: attachments.isEmpty ? nil : attachments))
        let response = ChatMessage(role: .assistant, text: "", state: .streaming)
        messages.append(response)
        return response.id
    }

    public mutating func append(_ chunk: String, to responseID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].append(chunk)
    }

    public mutating func finish(responseID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].finish()
    }

    public mutating func appendReasoning(_ chunk: String, to responseID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }), messages[index].role == .assistant else { return }
        messages[index].appendReasoning(chunk)
    }

    public mutating func stop(responseID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].stop()
    }

    public mutating func fail(responseID: UUID, description: String) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].fail(with: description)
    }

    public mutating func addNotice(_ text: String) {
        messages.append(ChatMessage(role: .notice, text: text))
    }

    public mutating func clear() {
        messages.removeAll(keepingCapacity: true)
    }

    /// A saved streaming response has no live generation to finish it after launch.
    /// Keep its partial text visible, independently of the completed model context.
    public mutating func markInterruptedResponsesStopped() {
        for index in messages.indices where messages[index].state == .streaming {
            messages[index].stop()
        }
    }
}
