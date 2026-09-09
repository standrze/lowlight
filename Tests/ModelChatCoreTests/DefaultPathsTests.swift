import Foundation
import Testing
@testable import ModelChatCore

@Test func settingsPreferLowlightDefaultsAndExplicitOverrides() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent(".lowlight/config/settings.json")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent("model-stack.local.json")
    try Data("{}".utf8).write(to: legacy)
    #expect(try SettingsFileLocator.find(explicitPath: nil, home: root, environment: [:], workingDirectory: root) == legacy)
    try Data("{}".utf8).write(to: config)
    #expect(try SettingsFileLocator.find(explicitPath: nil, home: root, environment: [:], workingDirectory: root) == config)
    #expect(try SettingsFileLocator.find(explicitPath: nil, home: root, environment: ["LOWLIGHT_CONFIG": legacy.path], workingDirectory: root) == legacy)
    #expect(try SettingsFileLocator.find(explicitPath: config.path, home: root, environment: ["LOWLIGHT_CONFIG": legacy.path], workingDirectory: root) == config)
    #expect(throws: ModelStackSettingsError.self) {
        try SettingsFileLocator.find(explicitPath: nil, home: root, environment: ["LOWLIGHT_CONFIG": root.appendingPathComponent("missing").path], workingDirectory: root)
    }
}

@Test func legacyProfilesRemainReadableAndSaveToLowlight() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let legacy = ConnectionProfileStore(directory: home.appendingPathComponent(".midnight/profiles"))
    let original = ConnectionProfile(name: "local", endpoint: "http://localhost:8080/v1", model: "old")
    try legacy.save(original)
    let store = ConnectionProfileStore(home: home)
    #expect(try store.load("local") == original)
    #expect(try store.list().profiles == [original])
    var updated = original
    updated.model = "new"
    try store.save(updated)
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".lowlight/config/profiles/local.json").path))
    #expect(try store.load("local") == updated)
    #expect(try store.list().profiles == [updated])
    #expect(try legacy.load("local") == original)
    try Data("invalid".utf8).write(to: store.directory.appendingPathComponent("local.json"))
    #expect(throws: (any Error).self) { try store.load("local") }
    #expect(try store.list().profiles.isEmpty)
    #expect(try store.list().warnings.count == 1)
}
