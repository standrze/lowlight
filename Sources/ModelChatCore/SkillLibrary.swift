import Foundation

/// An activation-time snapshot. Resuming a conversation does not reread the source file.
public struct SkillDocument: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let body: String
    public let sourcePath: String

    public init(name: String, description: String, body: String, sourcePath: String) {
        self.name = name
        self.description = description
        self.body = body
        self.sourcePath = sourcePath
    }
}

/// Metadata for the local selector. The catalog is never part of the model prompt.
public struct SkillSummary: Equatable, Sendable {
    public let name: String
    public let description: String
    public let sourcePath: String
    public var path: String { sourcePath }

    public init(name: String, description: String, sourcePath: String) {
        self.name = name
        self.description = description
        self.sourcePath = sourcePath
    }
}

public struct SkillCatalog: Equatable, Sendable {
    public let skills: [SkillSummary]
    public let warnings: [String]
}

public struct SkillLibraryError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Reads only SKILL.md files one directory below the configured roots.
///
/// Workspace instructions precede personal skills; legacy roots remain readable.
/// Duplicate names never merge.
/// This supports instruction files, not plugin installation or script execution.
public struct SkillLibrary: Sendable {
    public static let maximumFileBytes = 128 * 1_024
    private let roots: [URL]
    private let creationRoot: URL

    public init(workspace: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        creationRoot = home.appendingPathComponent(".lowlight/skills", isDirectory: true).standardizedFileURL
        roots = [
            workspace.appendingPathComponent(".lowlight/skills", isDirectory: true),
            workspace.appendingPathComponent(".agents/skills", isDirectory: true),
            workspace.appendingPathComponent(".midnight/skills", isDirectory: true),
            home.appendingPathComponent(".lowlight/skills", isDirectory: true),
            home.appendingPathComponent(".agents/skills", isDirectory: true),
            home.appendingPathComponent(".config/midnight/skills", isDirectory: true),
            home.appendingPathComponent(".codex/skills", isDirectory: true),
        ].map(\.standardizedFileURL)
    }

    public func scan() -> SkillCatalog {
        let result = scanDocuments()
        return SkillCatalog(
            skills: result.documents.map {
                SkillSummary(name: $0.name, description: $0.description, sourcePath: $0.sourcePath)
            },
            warnings: result.warnings
        )
    }

    public func catalog() throws -> [SkillSummary] {
        scan().skills
    }

    public func load(name: String) throws -> SkillDocument {
        let result = scanDocuments()
        if let document = result.documents.first(where: { $0.name == name }) {
            return document
        }
        let diagnostics = result.warnings.isEmpty ? "" : "\n" + result.warnings.joined(separator: "\n")
        throw SkillLibraryError(message:
            "Skill '\(name)' was not found. Use /skill list to see available names.\(diagnostics)"
        )
    }

    public func validateNewName(_ name: String) throws {
        guard isValidName(name) else { throw invalid("Use 1–64 lowercase letters, digits, and single hyphens for the skill name.") }
    }

    /// Creates only a new personal instruction file. Existing files are never replaced.
    public func create(name: String, markdown: String) throws -> SkillDocument {
        try validateNewName(name)
        let file = creationRoot.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        let data = Data(markdown.utf8)
        guard data.count <= Self.maximumFileBytes else { throw invalid("Skill exceeds the 128 KiB limit.") }
        let document = try parse(markdown, file: file)
        guard document.name == name else { throw invalid("The frontmatter name must remain '\(name)'.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .withoutOverwriting)
        return document
    }

    private func scanDocuments() -> (documents: [SkillDocument], warnings: [String]) {
        let manager = FileManager.default
        var documents: [String: SkillDocument] = [:]
        var warnings: [String] = []
        var visitedRoots: Set<String> = []
        for root in roots {
            guard visitedRoots.insert(root.path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                warnings.append("\(root.path): expected a skills directory.")
                continue
            }
            do {
                let children = try manager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    let file = child.appendingPathComponent("SKILL.md")
                    do {
                        guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                              manager.fileExists(atPath: file.path) else { continue }
                        let document = try read(file)
                        if let winner = documents[document.name] {
                            warnings.append("\(file.path): duplicate skill '\(document.name)' ignored; using \(winner.sourcePath).")
                        } else {
                            documents[document.name] = document
                        }
                    } catch {
                        warnings.append("\(file.path): \(error.localizedDescription)")
                    }
                }
            } catch {
                warnings.append("\(root.path): could not list skills: \(error.localizedDescription)")
            }
        }
        return (documents.values.sorted { $0.name < $1.name }, warnings)
    }

    private func read(_ file: URL) throws -> SkillDocument {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw invalid("SKILL.md must be a regular text file.")
        }
        guard (values.fileSize ?? 0) <= Self.maximumFileBytes else {
            throw invalid("SKILL.md exceeds the 128 KiB limit; shorten the instructions.")
        }
        // Bound the actual read as well as the initial size check in case the file changes.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else {
            throw invalid("SKILL.md exceeds the 128 KiB limit; shorten the instructions.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw invalid("save SKILL.md as UTF-8 text.")
        }
        return try parse(text, file: file)
    }

    private func parse(_ markdown: String, file: URL) throws -> SkillDocument {
        var text = markdown
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" }) else {
            throw invalid("add YAML frontmatter delimited by --- with name and description fields.")
        }
        let fields = try parseFrontmatter(Array(lines[1..<end]))
        guard let name = fields["name"], isValidName(name) else {
            throw invalid("name must be 1–64 lowercase letters, digits, or single hyphens, with no leading or trailing hyphen.")
        }
        guard let description = fields["description"], !description.isEmpty,
              description.count <= 1_024, !hasUnsupportedControls(description) else {
            throw invalid("description must be nonempty text of at most 1024 characters.")
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasUnsupportedControls(body) else {
            throw invalid("add a nonempty Markdown instruction body after the closing ---; control characters are not supported.")
        }
        return SkillDocument(name: name, description: description, body: body, sourcePath: file.path)
    }

    /// A deliberately limited frontmatter reader, not a general YAML parser.
    /// Supports plain, single/double quoted, and |/> block scalars for name and
    /// description. Unused fields (including nested metadata) are ignored.
    private func parseFrontmatter(_ lines: [String]) throws -> [String: String] {
        var fields: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Nested fields belong to unused metadata; never treat them as top-level fields.
            if line.first?.isWhitespace == true { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw invalid("frontmatter line \(index + 1) needs a key: value field.")
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == "name" || key == "description" else { continue }
            guard fields[key] == nil else { throw invalid("frontmatter contains duplicate '\(key)' fields.") }
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let withoutComment = stripPlainComment(raw)
            let value: String
            if ["|", "|-", "|+", ">", ">-", ">+"].contains(withoutComment) {
                var block: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    if !next.trimmingCharacters(in: .whitespaces).isEmpty, next.first?.isWhitespace != true { break }
                    guard !next.hasPrefix("\t") else {
                        throw invalid("indent block descriptions with spaces, not tabs.")
                    }
                    block.append(next)
                    index += 1
                }
                let indent = block.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
                let content = block.map { String($0.dropFirst(min(indent, $0.count))) }
                if withoutComment.hasPrefix(">") {
                    value = foldBlock(content)
                } else {
                    value = content.joined(separator: "\n")
                }
            } else {
                value = try parseScalar(raw, key: key)
                if index < lines.count {
                    let next = lines[index]
                    if next.first?.isWhitespace == true,
                       !next.trimmingCharacters(in: .whitespaces).isEmpty,
                       !next.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                        throw invalid("use > or | for a multiline '\(key)' value.")
                    }
                }
            }
            fields[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fields
    }

    private func parseScalar(_ raw: String, key: String) throws -> String {
        if raw.hasPrefix("\"") {
            var escaped = false
            var end: String.Index?
            for index in raw.indices.dropFirst() {
                if escaped { escaped = false; continue }
                if raw[index] == "\\" { escaped = true; continue }
                if raw[index] == "\"" { end = index; break }
            }
            guard let end, validScalarSuffix(String(raw[raw.index(after: end)...])),
                  let decoded = try? JSONDecoder().decode(String.self, from: Data(raw[...end].utf8)) else {
                throw invalid("use a single-line quoted '\(key)' with JSON-style escapes, or a |/> block scalar.")
            }
            return decoded
        }
        if raw.hasPrefix("'") {
            var value = ""
            var index = raw.index(after: raw.startIndex)
            while index < raw.endIndex {
                let next = raw.index(after: index)
                if raw[index] == "'" {
                    if next < raw.endIndex, raw[next] == "'" {
                        value.append("'")
                        index = raw.index(after: next)
                        continue
                    }
                    guard validScalarSuffix(String(raw[next...])) else {
                        throw invalid("unexpected text after quoted '\(key)'.")
                    }
                    return value
                }
                value.append(raw[index])
                index = next
            }
            throw invalid("close the single quote around '\(key)', or use a |/> block scalar.")
        }
        let value = stripPlainComment(raw)
        if let first = value.first, "[{&*!|>%@`".contains(first) {
            throw invalid("'\(key)' must be plain text, quoted text, or a |/> block scalar; YAML collections, tags, and aliases are unsupported.")
        }
        return value
    }

    private func stripPlainComment(_ value: String) -> String {
        for index in value.indices where value[index] == "#" {
            if index == value.startIndex || value[value.index(before: index)].isWhitespace {
                return String(value[..<index]).trimmingCharacters(in: .whitespaces)
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private func validScalarSuffix(_ suffix: String) -> Bool {
        let trimmed = suffix.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private func foldBlock(_ lines: [String]) -> String {
        var result = ""
        for index in lines.indices {
            if index > 0 {
                let previous = lines[index - 1]
                let current = lines[index]
                if previous.isEmpty || current.isEmpty || previous.hasPrefix(" ") || current.hasPrefix(" ") {
                    result += "\n"
                } else {
                    result += " "
                }
            }
            result += lines[index]
        }
        return result
    }

    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64
            && name.first != "-" && name.last != "-" && !name.contains("--")
            && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private func hasUnsupportedControls(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
    }

    private func invalid(_ reason: String) -> SkillLibraryError {
        SkillLibraryError(message: reason)
    }
}

/// Preserve the user's canonical base prompt separately from active skill snapshots.
/// No inactive metadata, source paths, linked files, or scripts enter this prompt.
public func composeSystemPrompt(base: String?, skills: [SkillDocument]) -> String? {
    guard !skills.isEmpty else { return base }
    let instructions = skills.map { "### Skill: \($0.name)\n\($0.body)" }.joined(separator: "\n\n")
    let active = "## Active skills\nApply these instructions when relevant to the user's request.\n\n\(instructions)"
    guard let base, !base.isEmpty else { return active }
    return base + "\n\n" + active
}
