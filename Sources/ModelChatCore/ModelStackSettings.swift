import Foundation

public struct ModelStackSettings: Decodable, Sendable {
    public struct Chat: Decodable, Sendable {
        public struct Context: Decodable, Sendable {
            public let windowTokens: Int?
            public let safetyReserveTokens: Int?
            public let compactAtPercent: Int?
            public let strategy: ContextStrategy?
            public let systemPrompt: String?
        }

        public let endpoint: String?
        public let model: String?
        public let apiKeyEnvironment: String?
        public let maximumTokens: Int?
        public let audioOutputDirectory: String?
        public let context: Context?
    }

    public let chat: Chat?

    public static func load(explicitPath: String?) throws -> Self? {
        guard let url = try SettingsFileLocator.find(explicitPath: explicitPath) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            throw ModelStackSettingsError.invalidFile(url.path, error.localizedDescription)
        }
    }
}

public enum ModelStackSettingsError: LocalizedError {
    case missingFile(String)
    case invalidFile(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            "Settings file does not exist: \(path)"
        case .invalidFile(let path, let detail):
            "Could not read settings file \(path): \(detail)"
        }
    }
}

enum SettingsFileLocator {
    static func find(explicitPath: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> URL? {
        let fileManager = FileManager.default
        if let explicitPath = explicitPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty
        {
            let url = normalizedURL(explicitPath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw ModelStackSettingsError.missingFile(url.path)
            }
            return url
        }

        if let environmentPath = environment["LOWLIGHT_CONFIG"] ?? environment["MODEL_STACK_CONFIG"],
           !environmentPath.isEmpty
        {
            let url = normalizedURL(environmentPath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw ModelStackSettingsError.missingFile(url.path)
            }
            return url
        }

        let candidates = [
            home.appendingPathComponent(".lowlight/config/settings.json"),
            workingDirectory.appendingPathComponent("model-stack.local.json"),
            workingDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("model-stack.local.json"),
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private static func normalizedURL(_ path: String) -> URL {
        URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath
        ).standardizedFileURL
    }
}
