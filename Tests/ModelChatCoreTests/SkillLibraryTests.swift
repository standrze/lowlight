import Foundation
import Testing
@testable import ModelChatCore

private struct SkillFixture {
    let root: URL
    let workspace: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("midnight-skills-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var library: SkillLibrary { SkillLibrary(workspace: workspace, home: home) }

    func write(_ text: String, under location: URL, path: String) throws -> URL {
        let file = location.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test
func creatingSkillWritesProjectFileAndRefusesOverwrite() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    let markdown = "---\nname: notes\ndescription: Summarize notes.\n---\nPreserve decisions and dates."
    let created = try fixture.library.create(name: "notes", markdown: markdown)
    #expect(created.sourcePath.hasSuffix("/.midnight/skills/notes/SKILL.md"))
    #expect(try fixture.library.load(name: "notes").body == "Preserve decisions and dates.")
    #expect(throws: (any Error).self) {
        try fixture.library.create(name: "notes", markdown: markdown + "\nReplacement.")
    }
    #expect(try String(contentsOfFile: created.sourcePath, encoding: .utf8) == markdown)
}

@Test
func creatingSkillValidatesBeforeWriting() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    #expect(throws: (any Error).self) {
        try fixture.library.create(name: "../escape", markdown: "invalid")
    }
    #expect(throws: (any Error).self) {
        try fixture.library.create(name: "notes", markdown: "---\nname: other\ndescription: Notes\n---\nInstructions")
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(".midnight").path))
}

@Test
func skillDiscoveryPrefersProjectInstructionsAndReportsDuplicates() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    let project = try fixture.write("""
        ---
        name: concise
        description: Project writing instructions.
        ---
        Write short paragraphs.
        """, under: fixture.workspace, path: ".agents/skills/concise/SKILL.md")
    _ = try fixture.write("""
        ---
        name: concise
        description: Personal writing instructions.
        ---
        Use long explanations.
        """, under: fixture.home, path: ".agents/skills/concise/SKILL.md")
    _ = try fixture.write("""
        ---
        name: glossary
        description: Define unfamiliar terms.
        ---
        Explain abbreviations on first use.
        """, under: fixture.home, path: ".config/midnight/skills/glossary/SKILL.md")

    let result = fixture.library.scan()
    #expect(result.skills.map(\.name) == ["concise", "glossary"])
    #expect(URL(fileURLWithPath: result.skills[0].sourcePath).resolvingSymlinksInPath().standardizedFileURL
        == project.resolvingSymlinksInPath().standardizedFileURL)
    #expect(result.warnings.count == 1)
    #expect(result.warnings[0].contains("duplicate skill 'concise'"))
    #expect(try fixture.library.load(name: "concise").body == "Write short paragraphs.")
}

@Test
func skillDiscoveryReadsMidnightAndCodexDirectoriesWithoutRecursing() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    let content = "---\nname: writing\ndescription: Writing guidance.\n---\nUse plain language."
    _ = try fixture.write(content, under: fixture.workspace, path: ".midnight/skills/writing/SKILL.md")
    _ = try fixture.write(content.replacingOccurrences(of: "name: writing", with: "name: fallback"),
                          under: fixture.home, path: ".codex/skills/fallback/SKILL.md")
    _ = try fixture.write(content.replacingOccurrences(of: "name: writing", with: "name: nested"),
                          under: fixture.workspace, path: ".agents/skills/plugin/nested/SKILL.md")

    #expect(try fixture.library.catalog().map(\.name) == ["fallback", "writing"])
}

@Test
func skillActivationStripsMetadataAndLeavesInactiveInstructionsOutOfPrompt() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("""
        ---
        name: active
        description: Selector metadata only.
        metadata:
          name: ignored-nested-name
        ---
        Preserve the user's terminology.
        """, under: fixture.workspace, path: ".agents/skills/active/SKILL.md")
    _ = try fixture.write("""
        ---
        name: inactive
        description: Other metadata.
        ---
        INACTIVE BODY MUST STAY LOCAL.
        """, under: fixture.workspace, path: ".agents/skills/inactive/SKILL.md")

    #expect(fixture.library.scan().skills.count == 2)
    let active = try fixture.library.load(name: "active")
    let base = "  Preserve this exact base prompt.\n"
    let prompt = try #require(composeSystemPrompt(base: base, skills: [active]))
    #expect(prompt.hasPrefix(base + "\n\n"))
    #expect(prompt.contains("Preserve the user's terminology."))
    #expect(!prompt.contains("Selector metadata"))
    #expect(!prompt.contains("INACTIVE BODY"))
    #expect(!prompt.contains(active.sourcePath))
    #expect(!active.body.contains("metadata:"))
    #expect(composeSystemPrompt(base: base, skills: []) == base)
    #expect(composeSystemPrompt(base: nil, skills: []) == nil)
    #expect(composeSystemPrompt(base: "", skills: []) == "")
}

@Test
func savedSkillSnapshotSurvivesFileChangesAndDeletion() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    let file = try fixture.write("""
        ---
        name: snapshot
        description: Stable session instructions.
        ---
        Original instructions.
        """, under: fixture.workspace, path: ".agents/skills/snapshot/SKILL.md")
    let active = try fixture.library.load(name: "snapshot")
    let saved = try JSONEncoder().encode(active)
    try Data("Changed file".utf8).write(to: file)
    try FileManager.default.removeItem(at: file)
    let resumed = try JSONDecoder().decode(SkillDocument.self, from: saved)

    #expect(resumed == active)
    #expect(composeSystemPrompt(base: nil, skills: [resumed])?.contains("Original instructions.") == true)
}

@Test
func skillFrontmatterSupportsQuotedDescriptionsAndComments() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("""
        ---
        name: "quoted" # selector name
        description: 'Use the user''s terms: keep # tags.' # local comment
        ---
        Follow the requested style.
        """, under: fixture.workspace, path: ".agents/skills/quoted/SKILL.md")
    let skill = try fixture.library.load(name: "quoted")
    #expect(skill.description == "Use the user's terms: keep # tags.")

    _ = try fixture.write("""
        ---
        name: plain
        description: Link https://example.com/#part clearly. # comment
        ---
        Explain links.
        """, under: fixture.workspace, path: ".agents/skills/plain/SKILL.md")
    #expect(try fixture.library.load(name: "plain").description == "Link https://example.com/#part clearly.")
}

@Test
func skillFrontmatterSupportsFoldedAndLiteralBlockDescriptions() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("""
        ---
        name: folded
        description: >-
          Explain a concept
          with concrete examples.
        metadata:
          short-description: Examples
        ---
        Start with an example.
        """, under: fixture.workspace, path: ".agents/skills/folded/SKILL.md")
    _ = try fixture.write("""
        ---
        name: literal
        description: |
          First line.
          Second line.
        ---
        Keep the structure.
        """, under: fixture.workspace, path: ".agents/skills/literal/SKILL.md")
    #expect(try fixture.library.load(name: "folded").description == "Explain a concept with concrete examples.")
    #expect(try fixture.library.load(name: "literal").description == "First line.\nSecond line.")
}

@Test
func brokenAndOversizedSkillsProduceWarningsWithoutBlockingValidSkills() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    let invalidDocuments = [
        "missing": "No frontmatter.",
        "bad-name": "---\nname: ../escape\ndescription: Invalid name.\n---\nBody.",
        "no-body": "---\nname: no-body\ndescription: Empty body.\n---\n   ",
        "duplicate": "---\nname: first\nname: second\ndescription: Duplicate key.\n---\nBody.",
        "unsupported": "---\nname: unsupported\ndescription: [a, b]\n---\nBody.",
        "oversized": String(repeating: "a", count: SkillLibrary.maximumFileBytes + 1),
    ]
    for (folder, content) in invalidDocuments {
        _ = try fixture.write(content, under: fixture.workspace, path: ".agents/skills/\(folder)/SKILL.md")
    }
    _ = try fixture.write("---\nname: valid\ndescription: Working skill.\n---\nUseful instructions.",
                          under: fixture.workspace, path: ".agents/skills/valid/SKILL.md")
    let result = fixture.library.scan()
    #expect(result.skills.map(\.name) == ["valid"])
    #expect(result.warnings.count == invalidDocuments.count)
    #expect(result.warnings.allSatisfy { $0.contains("SKILL.md:") })
    #expect(result.warnings.contains { $0.contains("128 KiB") })
    #expect(throws: SkillLibraryError.self) { try fixture.library.load(name: "missing") }
}

@Test
func malformedPreferredSkillFallsBackToValidPersonalSkill() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("Broken frontmatter", under: fixture.workspace, path: ".agents/skills/notes/SKILL.md")
    let fallback = try fixture.write("---\nname: notes\ndescription: Personal notes.\n---\nPreserve key facts.",
                                    under: fixture.home, path: ".agents/skills/notes/SKILL.md")
    let loaded = try fixture.library.load(name: "notes")
    #expect(URL(fileURLWithPath: loaded.sourcePath).resolvingSymlinksInPath().standardizedFileURL
        == fallback.resolvingSymlinksInPath().standardizedFileURL)
    #expect(fixture.library.scan().warnings.count == 1)
}

@Test
func invalidUTF8AndTerminalControlsAreRejected() throws {
    let fixture = try SkillFixture()
    defer { fixture.remove() }
    let invalid = try fixture.write("placeholder", under: fixture.workspace, path: ".agents/skills/invalid/SKILL.md")
    try Data([0xFF, 0xFE]).write(to: invalid)
    _ = try fixture.write("---\nname: escape\ndescription: Terminal controls.\n---\nBody\u{001B}[31m",
                          under: fixture.workspace, path: ".agents/skills/escape/SKILL.md")
    #expect(fixture.library.scan().skills.isEmpty)
    #expect(fixture.library.scan().warnings.count == 2)
}
