import Foundation
import ModelTransport

public struct ConnectionProfile: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var endpoint: String
    public var model: String
    /// Omitted by older profiles; new connections default to automatic selection.
    public var api: OpenAIAPI?
    public var apiKeyEnvironment: String
    public var contextWindow: Int
    public var maximumTokens: Int
    public var safetyReserve: Int
    public var compactAtPercent: Int
    public var reasoningEffort: ReasoningEffort?
    public var id: String { name }

    public init(name: String, endpoint: String, model: String, apiKeyEnvironment: String = "OPENAI_API_KEY",
                contextWindow: Int = 32_768, maximumTokens: Int = 512, safetyReserve: Int = 1_024,
                compactAtPercent: Int = 90, reasoningEffort: ReasoningEffort? = nil,
                api: OpenAIAPI? = nil) {
        self.name = name; self.endpoint = endpoint; self.model = model
        self.api = api
        self.apiKeyEnvironment = apiKeyEnvironment; self.contextWindow = contextWindow
        self.maximumTokens = maximumTokens; self.safetyReserve = safetyReserve
        self.compactAtPercent = compactAtPercent; self.reasoningEffort = reasoningEffort
    }

    public func validate() throws {
        try ConnectionProfileStore.validateName(name)
        guard let url = URLComponents(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConversationFeatureError.message("Use an HTTP(S) endpoint without embedded credentials, query, or fragment.")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ChatAttachment.isDisplayable(model, multiline: false),
              Self.validEnvironmentName(apiKeyEnvironment) else {
            throw ConversationFeatureError.message("Provide a model name and an environment-variable name for authentication, not an API key.")
        }
        _ = try ContextPolicy(windowTokens: contextWindow, maximumOutputTokens: maximumTokens,
                              safetyReserveTokens: safetyReserve, compactAtPercent: compactAtPercent)
    }

    public static func validEnvironmentName(_ value: String) -> Bool {
        let chars = Array(value.utf8)
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
        return !chars.isEmpty && letter(chars[0]) && chars.allSatisfy { letter($0) || (48...57).contains($0) }
    }
}

public struct ConnectionProfileStore: Sendable {
    public let directory: URL
    private let fallbackDirectory: URL?
    public init(directory: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = directory ?? home.appendingPathComponent(".lowlight/config/profiles")
        self.fallbackDirectory = directory == nil ? home.appendingPathComponent(".midnight/profiles") : nil
    }

    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard (1...64).contains(name.utf8.count), name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ConversationFeatureError.message("Profile names use 1–64 letters, digits, dashes, or underscores.")
        }
    }

    public func load(_ name: String) throws -> ConnectionProfile {
        try Self.validateName(name)
        var url = directory.appendingPathComponent(name + ".json")
        if !FileManager.default.fileExists(atPath: url.path),
           (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
           let fallbackDirectory {
            url = fallbackDirectory.appendingPathComponent(name + ".json")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 32_768 else {
            throw ConversationFeatureError.message("A profile must be a regular JSON file under 32 KiB.")
        }
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(contentsOf: url))
        try profile.validate()
        guard profile.name == name else { throw ConversationFeatureError.message("Profile name does not match its filename.") }
        return profile
    }

    public func list() throws -> (profiles: [ConnectionProfile], warnings: [String]) {
        let directories = [directory] + (fallbackDirectory.map { [$0] } ?? [])
        var urls: [URL] = []
        for folder in directories where FileManager.default.fileExists(atPath: folder.path) {
            urls += try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        var seen = Set<String>()
        var profiles: [ConnectionProfile] = [], warnings: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            guard seen.insert(url.lastPathComponent).inserted else { continue }
            do { profiles.append(try load(url.deletingPathExtension().lastPathComponent)) }
            catch { warnings.append("Skipped \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (profiles, warnings)
    }

    public func save(_ profile: ConnectionProfile) throws {
        try profile.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(profile.name + ".json")
        if FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            _ = try load(profile.name)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url, options: .atomic)
    }
}

public enum ConnectionDiagnostics {
    public static func describe(_ error: Error, endpoint: String, apiKeyEnvironment: String) -> String {
        let hint: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                hint = "Check that the server is running and the host/port are correct."
            case .timedOut: hint = "The server timed out. Check its logs and model load status."
            default: hint = "Check the endpoint and network connection."
            }
        } else if let endpointError = error as? EndpointSessionError, case .httpStatus(let code) = endpointError {
            switch code {
            case 401, 403: hint = "Check the \(apiKeyEnvironment) environment variable and server authentication."
            case 404: hint = "Check the API base URL and selected model."
            case 429: hint = "The server is rate-limiting requests; wait before retrying."
            default: hint = "Check the server logs and request settings."
            }
        } else { hint = "Check /connection and the server logs." }
        return "\(endpoint)\n\(error.localizedDescription)\n\(hint)"
    }
}
