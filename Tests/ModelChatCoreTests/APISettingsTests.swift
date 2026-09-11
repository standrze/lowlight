import Foundation
import ModelTransport
import Testing
@testable import ModelChatCore

@Test(arguments: [OpenAIAPI.auto, .responses, .chatCompletions])
func apiSelectionDecodesFromSettings(_ api: OpenAIAPI) throws {
    let data = try JSONSerialization.data(withJSONObject: ["chat": ["api": api.rawValue]])
    let settings = try JSONDecoder().decode(ModelStackSettings.self, from: data)
    #expect(settings.chat?.api == api)
}

@Test func apiSettingsRejectUnknownSelectionAndAllowOlderFiles() throws {
    let decoder = JSONDecoder()
    let old = try decoder.decode(ModelStackSettings.self, from: Data(#"{"chat":{"model":"local"}}"#.utf8))
    #expect(old.chat?.api == nil)
    #expect(throws: DecodingError.self) {
        try decoder.decode(ModelStackSettings.self, from: Data(#"{"chat":{"api":"unsupported"}}"#.utf8))
    }
}

@Test(arguments: [OpenAIAPI.auto, .responses, .chatCompletions])
func apiSelectionRoundTripsInProfilesAndConversations(_ api: OpenAIAPI) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profiles = ConnectionProfileStore(directory: directory.appendingPathComponent("profiles"))
    let profile = ConnectionProfile(name: "local", endpoint: "http://localhost:8080/v1", model: "local", api: api)
    try profiles.save(profile)
    #expect(try profiles.load("local").api == api)

    let conversations = ConversationStore(directory: directory.appendingPathComponent("conversations"))
    let conversation = SavedConversation(model: "local", endpoint: profile.endpoint, api: api)
    try conversations.save(conversation)
    #expect(try conversations.load(conversation.id.uuidString).api == api)
}

@Test func olderProfilesAndConversationsHaveNoExplicitAPI() throws {
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let profile = ConnectionProfile(name: "local", endpoint: "http://localhost:8080/v1", model: "local")
    let profileData = try encoder.encode(profile)
    let profileJSON = try #require(JSONSerialization.jsonObject(with: profileData) as? [String: Any])
    #expect(profileJSON["api"] == nil)
    #expect(try decoder.decode(ConnectionProfile.self, from: profileData).api == nil)

    let conversation = SavedConversation(model: "local", endpoint: profile.endpoint)
    let conversationData = try encoder.encode(conversation)
    let conversationJSON = try #require(JSONSerialization.jsonObject(with: conversationData) as? [String: Any])
    #expect(conversationJSON["api"] == nil)
    #expect(try decoder.decode(SavedConversation.self, from: conversationData).api == nil)
    #expect(conversationJSON["schemaVersion"] as? Int == 1)
}
