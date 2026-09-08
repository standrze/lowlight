import Foundation

/// A text snapshot, not a live reference. Reading a file never sends it to a model.
public struct ChatAttachment: Codable, Equatable, Sendable, Identifiable {
    public static let maximumBytes = 128 * 1_024
    public static let maximumTotalBytes = 512 * 1_024
    public let id: UUID
    public let path: String
    public let text: String

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var estimatedTokens: Int { (text.utf8.count + path.utf8.count + 80 + 3) / 4 }

    public init(id: UUID = UUID(), path: String, text: String) {
        self.id = id
        self.path = path
        self.text = text
    }

    public static func read(_ path: String, workspace: URL) throws -> Self {
        var input = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.count >= 2, (input.first == "\"" && input.last == "\"" || input.first == "'" && input.last == "'") {
            input = String(input.dropFirst().dropLast())
        }
        guard !input.isEmpty else { throw ConversationFeatureError.message("Usage: /attach PATH") }
        let url = URL(fileURLWithPath: NSString(string: input).expandingTildeInPath,
                      relativeTo: URL(fileURLWithPath: workspace.path, isDirectory: true)).standardizedFileURL
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ConversationFeatureError.message("Attach a regular UTF-8 text file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw ConversationFeatureError.message("Attachments must be UTF-8 text and at most 128 KiB each.")
        }
        let attachment = Self(path: url.path, text: text)
        try validate([attachment])
        return attachment
    }

    public static func validate(_ attachments: [Self]) throws {
        guard attachments.count <= 8,
              Set(attachments.map(\.path)).count == attachments.count,
              attachments.allSatisfy({
                  ($0.path as NSString).isAbsolutePath && isDisplayable($0.path, multiline: false)
                      && $0.text.utf8.count <= maximumBytes && isDisplayable($0.text, multiline: true)
              }),
              attachments.reduce(0, { $0 + $1.text.utf8.count }) <= maximumTotalBytes else {
            throw ConversationFeatureError.message("Use up to 8 distinct text files (128 KiB each, 512 KiB total), without binary or terminal control characters.")
        }
    }

    static func isDisplayable(_ text: String, multiline: Bool) -> Bool {
        text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) || (multiline && [9, 10, 13].contains($0.value))
        }
    }

    public static func prompt(_ text: String, attachments: [Self]) -> String {
        guard !attachments.isEmpty else { return text }
        // Explicit boundaries identify file data; these do not confer instruction authority.
        let files = attachments.map { file in
            "--- Attached file: \(file.path) ---\n\(file.text)\n--- End attached file ---"
        }.joined(separator: "\n\n")
        return text + "\n\nThe following are attached file contents for reference:\n\n" + files
    }
}

public enum ConversationFeatureError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
