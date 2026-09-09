import Foundation
import ModelTransport

/// A portable chat snapshot. Authentication is supplied by the running client,
/// never by this record. Skill bodies are activation-time snapshots.
public struct SavedConversation: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The selected model, or empty for a draft created before discovery succeeds.
    public var model: String
    public var endpoint: String
    public var workspacePath: String
    public var maximumTokens: Int
    public var reasoningEffort: ReasoningEffort?
    public var contextWindowTokens: Int
    public var contextSafetyReserveTokens: Int
    public var contextCompactAtPercent: Int
    public var contextStrategy: ContextStrategy
    /// The user's base prompt, before active skill instructions are composed.
    public var systemPrompt: String?
    public var activeSkills: [SkillDocument]
    public var context: ConversationContextState
    public var transcript: ChatTranscript
    public var inputHistory: [String]
    /// Optional additions keep existing version-1 sessions readable.
    public var draft: String?
    public var pendingAttachments: [ChatAttachment]?
    public var archived: Bool?
    public var parentID: UUID?
    public var apiKeyEnvironment: String?

    public init(
        id: UUID = UUID(),
        title: String = "New conversation",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        model: String,
        endpoint: String,
        workspacePath: String = FileManager.default.currentDirectoryPath,
        maximumTokens: Int = 512,
        contextWindowTokens: Int = 32_768,
        contextSafetyReserveTokens: Int = 1_024,
        contextCompactAtPercent: Int = 90,
        contextStrategy: ContextStrategy = .slidingWindow,
        systemPrompt: String? = nil,
        activeSkills: [SkillDocument] = [],
        context: ConversationContextState = .init(),
        transcript: ChatTranscript = .init(),
        inputHistory: [String] = [],
        reasoningEffort: ReasoningEffort? = nil,
        draft: String? = nil,
        pendingAttachments: [ChatAttachment]? = nil,
        archived: Bool? = nil,
        parentID: UUID? = nil,
        apiKeyEnvironment: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.model = model
        self.endpoint = endpoint
        self.workspacePath = workspacePath
        self.maximumTokens = maximumTokens
        self.reasoningEffort = reasoningEffort
        self.contextWindowTokens = contextWindowTokens
        self.contextSafetyReserveTokens = contextSafetyReserveTokens
        self.contextCompactAtPercent = contextCompactAtPercent
        self.contextStrategy = contextStrategy
        self.systemPrompt = systemPrompt
        self.activeSkills = activeSkills
        self.context = context
        self.transcript = transcript
        self.inputHistory = inputHistory
        self.draft = draft
        self.pendingAttachments = pendingAttachments
        self.archived = archived
        self.parentID = parentID
        self.apiKeyEnvironment = apiKeyEnvironment
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConversationStoreError.unsupportedVersion(schemaVersion)
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationStoreError.invalidRecord("The conversation title is empty.")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (context == .init() && transcript.messages.allSatisfy { $0.role == .notice }) else {
            throw ConversationStoreError.invalidRecord("The model name is empty.")
        }
        guard !workspacePath.isEmpty, (workspacePath as NSString).isAbsolutePath else {
            throw ConversationStoreError.invalidRecord("The workspace path must be absolute.")
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt else {
            throw ConversationStoreError.invalidRecord("The conversation dates are invalid.")
        }
        _ = try Self.endpointWithoutCredentials(endpoint)
        _ = try ContextPolicy(
            windowTokens: contextWindowTokens,
            maximumOutputTokens: maximumTokens,
            safetyReserveTokens: contextSafetyReserveTokens,
            compactAtPercent: contextCompactAtPercent,
            strategy: contextStrategy,
            systemPrompt: systemPrompt
        )
        try context.validate()
        if let apiKeyEnvironment, !ConnectionProfile.validEnvironmentName(apiKeyEnvironment) {
            throw ConversationStoreError.invalidRecord("Authentication must reference an environment-variable name.")
        }
        try ChatAttachment.validate(pendingAttachments ?? [])
        for message in transcript.messages { try ChatAttachment.validate(message.attachments ?? []) }
        guard Set(transcript.messages.map(\.id)).count == transcript.messages.count else {
            throw ConversationStoreError.invalidRecord("The transcript has duplicate message identifiers.")
        }
        guard transcript.messages.allSatisfy({
            $0.role == .assistant || $0.state == .complete
        }) else {
            throw ConversationStoreError.invalidRecord("Only assistant messages can have generation state.")
        }
        guard Set(activeSkills.map(\.name)).count == activeSkills.count else {
            throw ConversationStoreError.invalidRecord("The conversation has duplicate active skills.")
        }
        for skill in activeSkills {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            guard (1...64).contains(skill.name.utf8.count),
                  skill.name.unicodeScalars.allSatisfy(allowed.contains),
                  !skill.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  skill.description.count <= 1_024,
                  !skill.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  skill.body.utf8.count <= 128 * 1_024,
                  !skill.sourcePath.isEmpty else {
                throw ConversationStoreError.invalidRecord("An active skill snapshot is invalid.")
            }
        }
    }

    fileprivate static func endpointWithoutCredentials(_ endpoint: String) throws -> String {
        guard var components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw ConversationStoreError.invalidRecord("The endpoint must be an HTTP or HTTPS URL.")
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let sanitized = components.string else {
            throw ConversationStoreError.invalidRecord("The endpoint URL is invalid.")
        }
        return sanitized
    }
}

public struct ConversationSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let model: String
    public let workspacePath: String
    public let archived: Bool
    public let hasDraft: Bool

    fileprivate init(_ conversation: SavedConversation) {
        id = conversation.id
        title = conversation.title
        updatedAt = conversation.updatedAt
        model = conversation.model
        workspacePath = conversation.workspacePath
        archived = conversation.archived == true
        hasDraft = !(conversation.draft ?? "").isEmpty || !(conversation.pendingAttachments ?? []).isEmpty
    }
}

public struct ConversationStoreWarning: Equatable, Sendable {
    public let filename: String
    public let message: String
}

public struct ConversationStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lowlight/sessions/chat", isDirectory: true)
    }

    public static var midnightDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".midnight/sessions/chat", isDirectory: true)
    }

    public static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Midnight Chat/sessions", isDirectory: true)
    }

    public let directory: URL
    private let fallbackDirectories: [URL]

    /// Older libraries remain readable. Saving a resumed chat writes to lowlight
    /// without deleting its old snapshot. An explicit directory is isolated.
    public init(directory: URL? = nil) {
        self.init(
            directory: directory ?? Self.defaultDirectory,
            fallbackDirectories: directory == nil ? [Self.midnightDirectory, Self.legacyDirectory] : []
        )
    }

    init(directory: URL, fallbackDirectory: URL?) {
        self.init(directory: directory, fallbackDirectories: fallbackDirectory.map { [$0] } ?? [])
    }

    init(directory: URL, fallbackDirectories: [URL]) {
        self.directory = directory.standardizedFileURL
        self.fallbackDirectories = fallbackDirectories.map(\.standardizedFileURL)
    }

    /// Writes to a temporary file and atomically replaces the snapshot. Validate
    /// first so invalid in-memory data cannot destroy the last successful save.
    @discardableResult
    public func save(_ conversation: SavedConversation) throws -> URL {
        var persisted = conversation
        persisted.endpoint = try SavedConversation.endpointWithoutCredentials(conversation.endpoint)
        try persisted.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(persisted)

        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        if manager.fileExists(atPath: destination.path) ||
            (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            do {
                _ = try read(destination)
            } catch {
                throw ConversationStoreError.wouldOverwriteInvalidRecord(destination.lastPathComponent)
            }
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Selects a UUID, an unambiguous UUID prefix, or the latest valid snapshot.
    public func load(_ selector: String) throws -> SavedConversation {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "last" {
            guard let newest = try scan().conversations.first(where: { $0.archived != true }) else {
                throw ConversationStoreError.noConversations
            }
            return newest
        }

        let allowed = CharacterSet(charactersIn: "0123456789abcdef-")
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ConversationStoreError.invalidSelector
        }
        let matches = try recordURLs().filter {
            $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(normalized)
        }
        guard !matches.isEmpty else { throw ConversationStoreError.notFound(selector) }
        guard matches.count == 1 else { throw ConversationStoreError.ambiguousSelector(selector) }
        return try read(matches[0])
    }

    public func list(query: String = "", includeArchived: Bool = false) throws -> [ConversationSummary] {
        try scan().conversations.filter {
            (includeArchived || $0.archived != true) && ($0.matches(query))
        }.map(ConversationSummary.init)
    }

    public func setArchived(_ selector: String, archived: Bool) throws {
        var saved = try load(selector)
        saved.archived = archived
        try save(saved)
    }

    /// Keep a recovery copy and a tombstone so a legacy fallback cannot resurrect a deletion.
    public func delete(_ selector: String) throws {
        let saved = try load(selector)
        let trash = directory.appendingPathComponent(".trash", isDirectory: true)
        let deleted = directory.appendingPathComponent(".deleted", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: deleted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ConversationStore(directory: trash).save(saved)
        let marker = deleted.appendingPathComponent(saved.id.uuidString)
        try Data().write(to: marker, options: .atomic)
        let current = directory.appendingPathComponent("\(saved.id.uuidString).json")
        do {
            if manager.fileExists(atPath: current.path) { try manager.removeItem(at: current) }
        } catch {
            try? manager.removeItem(at: marker)
            throw error
        }
    }

    /// Malformed records are retained on disk and do not hide healthy sessions.
    public func warnings() throws -> [ConversationStoreWarning] {
        try scan().warnings
    }

    private func recordURLs() throws -> [URL] {
        var records: [UUID: URL] = [:]
        var deletedIDs: Set<UUID> = []
        // A newer home's snapshot wins even if invalid. Its deletion markers
        // also hide older copies, while older markers cannot hide newer records.
        for root in [directory] + fallbackDirectories {
            deletedIDs.formUnion(try deletedRecordIDs(in: root))
            for url in try recordURLs(in: root) {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      records[id] == nil,
                      !deletedIDs.contains(id)
                else { continue }
                records[id] = url
            }
        }
        return records.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func deletedRecordIDs(in root: URL) throws -> Set<UUID> {
        let deleted = root.appendingPathComponent(".deleted", isDirectory: true)
        guard FileManager.default.fileExists(atPath: deleted.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(
            at: deleted,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).compactMap { UUID(uuidString: $0.lastPathComponent) })

    }

    private func recordURLs(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func read(_ url: URL) throws -> SavedConversation {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConversationStoreError.invalidRecord("Session files must be regular files, not links.")
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        // Check the version before decoding fields introduced by future formats.
        struct Version: Decodable { let schemaVersion: Int }
        let version = try decoder.decode(Version.self, from: data).schemaVersion
        guard version == SavedConversation.currentSchemaVersion else {
            throw ConversationStoreError.unsupportedVersion(version)
        }
        var conversation = try decoder.decode(SavedConversation.self, from: data)
        guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == conversation.id else {
            throw ConversationStoreError.invalidRecord("The session identifier does not match its filename.")
        }
        try conversation.validate()
        conversation.endpoint = try SavedConversation.endpointWithoutCredentials(conversation.endpoint)
        conversation.transcript.markInterruptedResponsesStopped()
        return conversation
    }

    private func scan() throws -> (
        conversations: [SavedConversation], warnings: [ConversationStoreWarning]
    ) {
        var conversations: [SavedConversation] = []
        var warnings: [ConversationStoreWarning] = []
        for url in try recordURLs() {
            do {
                conversations.append(try read(url))
            } catch {
                warnings.append(ConversationStoreWarning(
                    filename: url.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }
        conversations.sort {
            if $0.updatedAt == $1.updatedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.updatedAt > $1.updatedAt
        }
        return (conversations, warnings)
    }
}

public enum ConversationStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidRecord(String)
    case noConversations
    case invalidSelector
    case notFound(String)
    case ambiguousSelector(String)
    case wouldOverwriteInvalidRecord(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This conversation uses unsupported file version \(version)."
        case .invalidRecord(let reason):
            "Invalid saved conversation: \(reason)"
        case .noConversations:
            "No valid saved conversations were found."
        case .invalidSelector:
            "Use a conversation UUID, a unique UUID prefix, or 'last'."
        case .notFound(let selector):
            "No saved conversation matches '\(selector)'."
        case .ambiguousSelector(let selector):
            "More than one saved conversation matches '\(selector)'; use a longer UUID prefix."
        case .wouldOverwriteInvalidRecord(let filename):
            "The existing session \(filename) is invalid or unsupported and was left untouched."
        }
    }
}
