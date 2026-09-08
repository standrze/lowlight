import Foundation
import ModelChatCore
import ModelTransport
import SwiftTUI

private enum LowlightPalette {
    static let accent = Color(hexRGB: 0x7DE3D3)
    static let blue = Color(hexRGB: 0x5289E6)
    static let ink = Color(hexRGB: 0x30343E)
    static let muted = Color(hexRGB: 0x788398)
    static let border = Color(hexRGB: 0xA7AFBE)
    static let detailAccent = accent
    static let danger = Color(hexRGB: 0xBD4E40)
    static let appearance = TerminalAppearance(
        foregroundColor: ink, backgroundColor: .white, tintColor: accent
    )
}


/// A single text cell, with an ASCII fallback for terminals that request it.
private enum LowlightBrand {
    static var mark: String {
        let ascii = ProcessInfo.processInfo.environment["SWIFTTUI_ASCII"] ?? "0"
        return CommandLine.arguments.contains("--ascii") || (!ascii.isEmpty && ascii != "0") ? "_" : "◒"
    }
}

private enum SlashCommand: String, CaseIterable, Identifiable, Sendable {
    case clear = "/clear"
    case context = "/context"
    case help = "/help"
    case model = "/model"
    case mode = "/mode"
    case quit = "/exit"
    case set = "/set"
    case usage = "/usage"
    case new = "/new"
    case save = "/save"
    case sessions = "/sessions"
    case resume = "/resume"
    case system = "/system"
    case skills = "/skill"
    case compact = "/compact"
    case effort = "/effort"
    case attach = "/attach"
    case retry = "/retry"
    case edit = "/edit"
    case branch = "/branch"
    case search = "/search"
    case export = "/export"
    case profile = "/profile"
    case connection = "/connection"

    var id: String { rawValue }
    var name: String { rawValue }

    var usage: String {
        switch self {
        case .model: "/model [MODEL]"
        case .mode: "/mode chat|tts"
        case .set: "/set [NAME VALUE]"
        case .new: "/new [TITLE]"
        case .save: "/save [TITLE]"
        case .sessions: "/sessions [QUERY|archived|archive ID|restore ID|delete ID]"
        case .resume: "/resume ID|last"
        case .system: "/system [show|edit|set TEXT|file PATH|clear]"
        case .skills: "/skill [list|create NAME|use NAME|off NAME|clear]"
        case .compact: "/compact [GUIDANCE]"
        case .effort: "/effort [low|medium|high|default]"
        case .attach: "/attach [PATH|list|remove N|clear]"
        case .retry: "/retry [TURN]"
        case .edit: "/edit [TURN]"
        case .branch: "/branch [TURN]"
        case .search: "/search TEXT"
        case .export: "/export PATH"
        case .profile: "/profile [save NAME|use NAME]"
        case .connection: "/connection [reconnect]"
        case .clear, .context, .help, .quit, .usage: rawValue
        }
    }

    var description: String {
        switch self {
        case .clear: "Clear conversation"
        case .context: "Show context usage"
        case .help: "Show commands and keyboard shortcuts"
        case .model: "Select another model"
        case .mode: "Switch between chat and text-to-speech"
        case .quit: "Save and exit lowlight"
        case .set: "Show or change settings"
        case .usage: "Show standard OpenAI token usage"
        case .new: "Save this chat and start another"
        case .save: "Save or name this conversation"
        case .sessions: "Search and manage saved conversations"
        case .resume: "Resume a saved conversation"
        case .system: "View or change this chat's system prompt"
        case .skills: "Choose skills for this conversation"
        case .compact: "Summarize older context and retain the full transcript"
        case .effort: "Show or change reasoning effort"
        case .attach: "Preview and attach text files to the next message"
        case .retry: "Retry an answer in a new branch"
        case .edit: "Edit a previous message in a new branch"
        case .branch: "Continue a copy of this conversation"
        case .search: "Find text in this conversation"
        case .export: "Export this conversation as Markdown"
        case .profile: "Save or select a connection profile"
        case .connection: "Inspect connection and model capabilities"
        }
    }
}

@main
struct LowlightApp: App, SwiftTUICommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "lowlight",
        abstract: "lowlight — a terminal for your models.",
        version: "0.1.0-alpha.1"
    )

    @OptionGroup(title: "SwiftTUI Options")
    var swiftTUIOptions: SwiftTUIOptions

    @Option(name: .shortAndLong, help: "Model name exposed by the endpoint")
    var model: String?

    @Option(name: .shortAndLong, help: "OpenAI-compatible base URL")
    var endpoint: String?

    @Option(name: .long, help: "Named connection profile from ~/.midnight/profiles")
    var profile: String?

    @Option(name: .long, help: "Environment variable containing a bearer token")
    var apiKeyEnv: String?

    @Option(name: .shortAndLong, help: "Path to model-stack settings JSON")
    var config: String?

    @Option(name: .long, help: "Maximum tokens generated per response")
    var maxTokens: Int?

    @Option(name: .long, help: "Model context-window size")
    var contextWindow: Int?

    @Option(name: .long, help: "Directory for generated speech audio")
    var audioOutputDirectory: String?

    @Option(name: .long, help: "Tokens reserved as context safety headroom")
    var contextSafetyReserve: Int?

    @Option(name: .long, help: "Percent of the context window that triggers management")
    var contextCompactAt: Int?

    @Option(name: .long, help: "Resume a saved conversation ID, prefix, or last")
    var resume: String?

    @Option(name: .long, help: "Workspace for this conversation and its local skills")
    var workspace: String?

    @Option(name: .long, help: "Saved conversations directory (default: ~/.lowlight/sessions/chat)")
    var sessionsDirectory: String?

    @Option(name: .long, help: "System instructions for a new conversation")
    var systemPrompt: String?

    @Option(name: .long, help: "Read system instructions from a UTF-8 file")
    var systemPromptFile: String?

    @Option(name: .long, help: "Context strategy: checkpoint or slidingWindow")
    var contextStrategy: String?

    var body: some Scene {
        let settings = resolvedSettings
        WindowGroup("lowlight") {
            ChatView(
                initialModel: settings.model,
                endpoint: settings.endpoint,
                apiKeyEnvironment: settings.apiKeyEnvironment,
                initialEffort: settings.reasoningEffort,
                maximumTokens: settings.maximumTokens,
                contextWindowTokens: settings.contextWindowTokens,
                contextSafetyReserveTokens: settings.contextSafetyReserveTokens,
                contextCompactAtPercent: settings.contextCompactAtPercent,
                contextStrategy: settings.contextStrategy,
                systemPrompt: settings.systemPrompt,
                audioOutputDirectory: settings.audioOutputDirectory,
                startupError: settings.startupError,
                workspacePath: workspace ?? ProcessInfo.processInfo.environment["LOWLIGHT_WORKSPACE"]
                    ?? ProcessInfo.processInfo.environment["MIDNIGHT_WORKSPACE"]
                    ?? FileManager.default.currentDirectoryPath,
                sessionsDirectory: sessionsDirectory,
                resumeSelector: resume
            )
        }
    }

    private var resolvedSettings: ResolvedChatSettings {
        let fileSettings: ModelStackSettings?
        var startupError: String?
        do {
            fileSettings = try ModelStackSettings.load(explicitPath: config)
            startupError = nil
        } catch {
            fileSettings = nil
            startupError = error.localizedDescription
        }
        var selectedProfile: ConnectionProfile?
        if let profile {
            do { selectedProfile = try ConnectionProfileStore().load(profile) }
            catch { startupError = error.localizedDescription }
        }
        var prompt = systemPrompt ?? fileSettings?.chat?.context?.systemPrompt
        if let systemPromptFile {
            do {
                guard systemPrompt == nil else {
                    throw ChatInputError.message("Use either --system-prompt or --system-prompt-file.")
                }
                prompt = try readInstructionFile(systemPromptFile)
            } catch { startupError = error.localizedDescription }
        }
        let strategy = contextStrategy.flatMap(ContextStrategy.init(rawValue:))
            ?? fileSettings?.chat?.context?.strategy ?? .checkpoint
        if let contextStrategy, ContextStrategy(rawValue: contextStrategy) == nil {
            startupError = "Context strategy must be checkpoint or slidingWindow."
        }
        let resolvedEndpoint = endpoint ?? selectedProfile?.endpoint ?? fileSettings?.chat?.endpoint ?? "http://127.0.0.1:8080/v1"
        do { try validateChatEndpoint(resolvedEndpoint) }
        catch { startupError = error.localizedDescription }
        return ResolvedChatSettings(
            model: model ?? selectedProfile?.model ?? fileSettings?.chat?.model ?? "gemma-4-e2b-it-4bit",
            endpoint: resolvedEndpoint,
            apiKeyEnvironment: apiKeyEnv
                ?? selectedProfile?.apiKeyEnvironment
                ?? fileSettings?.chat?.apiKeyEnvironment
                ?? "OPENAI_API_KEY",
            maximumTokens: maxTokens ?? selectedProfile?.maximumTokens ?? fileSettings?.chat?.maximumTokens ?? 512,
            contextWindowTokens: contextWindow
                ?? selectedProfile?.contextWindow
                ?? fileSettings?.chat?.context?.windowTokens
                ?? 32_768,
            contextSafetyReserveTokens: contextSafetyReserve
                ?? selectedProfile?.safetyReserve
                ?? fileSettings?.chat?.context?.safetyReserveTokens
                ?? 1_024,
            contextCompactAtPercent: contextCompactAt
                ?? selectedProfile?.compactAtPercent
                ?? fileSettings?.chat?.context?.compactAtPercent
                ?? 90,
            contextStrategy: strategy,
            systemPrompt: prompt,
            audioOutputDirectory: audioOutputDirectory
                ?? fileSettings?.chat?.audioOutputDirectory
                ?? "tts-output",
            startupError: startupError,
            reasoningEffort: selectedProfile?.reasoningEffort
        )
    }
}

private struct ResolvedChatSettings {
    let model: String
    let endpoint: String
    let apiKeyEnvironment: String
    let maximumTokens: Int
    let contextWindowTokens: Int
    let contextSafetyReserveTokens: Int
    let contextCompactAtPercent: Int
    let contextStrategy: ContextStrategy
    let systemPrompt: String?
    let audioOutputDirectory: String
    let startupError: String?
    let reasoningEffort: ReasoningEffort?
}

@MainActor
private struct ChatView: View {
    private static let slashCommands: [SlashCommand] = [
        .model, .effort, .system, .skills, .resume, .sessions, .new, .save,
        .attach, .retry, .edit, .branch, .search, .export, .profile, .connection,
        .compact, .context, .usage, .set, .mode, .clear, .help, .quit
    ]
    private static let commandMenuRows = 6

    private enum AppMode: String, Equatable {
        case chat
        case tts

        var label: String { rawValue.uppercased() }
    }

    private enum ParsedSlashCommand {
        case clear
        case context
        case help
        case model(name: String)
        case mode(AppMode)
        case quit
        case set(argument: String?)
        case usage
        case local(SlashCommand, String?)
        case invalid(message: String)
    }

    private enum Phase: Equatable {
        case idle
        case configured
        case connecting
        case clearing
        case generating
        case synthesizing
        case error

        var label: String {
            switch self {
            case .idle: "offline"
            case .configured: "ready"
            case .connecting: "connecting"
            case .clearing: "clearing"
            case .generating: "generating"
            case .synthesizing: "synthesizing"
            case .error: "error"
            }
        }

        var color: Color {
            switch self {
            case .idle: LowlightPalette.muted
            case .connecting, .clearing, .generating, .synthesizing: LowlightPalette.accent
            case .configured: LowlightPalette.accent
            case .error: LowlightPalette.danger
            }
        }
    }

    private static let bottomAnchor = "transcript-bottom"

    private let initialModel: String
    @State private var endpoint: String
    @State private var appMode: AppMode = .chat
    @State private var ttsModel = "tts-1"
    @State private var ttsVoice = "alloy"
    @State private var ttsFormat = "mp3"
    @State private var audioOutputDirectory: String
    @State private var apiKeyEnvironment: String
    private var apiKey: String? { ProcessInfo.processInfo.environment[apiKeyEnvironment] }
    @State private var maximumTokens: Int
    @State private var contextWindowTokens: Int
    @State private var contextSafetyReserveTokens: Int
    @State private var contextCompactAtPercent: Int
    @State private var contextStrategy: ContextStrategy
    @State private var systemPrompt: String?
    private let startupError: String?
    private let store: ConversationStore
    private let resumeSelector: String?
    @State private var workspacePath: String
    @State private var conversationID = UUID()
    @State private var conversationTitle = "New conversation"
    @State private var conversationCreatedAt = Date()
    @State private var savedContext = ConversationContextState()
    @State private var activeSkills: [SkillDocument] = []
    @State private var saveError: String?
    @State private var editingSystem = false
    @State private var systemDraft = ""
    @State private var followsTranscript = true

    @Environment(\.requestTermination) private var requestTermination
    @State private var modelPath: String
    @State private var draft = ""
    @State private var transcript = ChatTranscript()
    @State private var session: EndpointModelSession?
    @State private var phase: Phase = .idle
    @State private var status = "Enter a model name exposed by the endpoint below."
    @State private var contextSnapshot: ContextSnapshot?
    @State private var lastPerformance: ModelRunnerPerformance?
    @State private var didAutoload = false
    @State private var generationTask: Task<Void, Never>?
    @State private var elapsedTimeTask: Task<Void, Never>?
    @State private var generationElapsedSeconds = 0
    @State private var clearTask: Task<Void, Never>?
    @State private var connectionTask: Task<Void, Never>?
    @State private var availableModels: [String] = []
    @State private var inputHistory: [String] = []
    @State private var historyIndex: Int?
    @State private var draftBeforeHistory = ""
    @FocusState private var promptIsFocused: Bool
    @State private var choosingSkills = false
    @State private var skillChoices: [SkillSummary] = []
    @State private var chosenSkillNames: Set<String> = []
    @State private var skillChoiceIndex = 0
    @State private var skillPickerError: String?
    @State private var creatingSkillName: String?
    @State private var instructionEditorError: String?
    @State private var commandChoiceIndex = 0
    @State private var dismissedCommandDraft: String?
    @State private var reasoningEffort: ReasoningEffort?
    @State private var showThinking = true
    @State private var confirmingExit = false
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var conversationArchived = false
    @State private var parentConversationID: UUID?
    @State private var modelCatalog: [OpenAIModel] = []
    @State private var retryAfterConnect = false
    @State private var scrollTarget: UUID?
    @State private var browser: BrowserKind?
    @State private var draftBeforeBrowser = ""
    private var browserQuery: String { draft }
    private var conversationDraft: String { browser == nil ? draft : draftBeforeBrowser }
    @State private var browserItems: [BrowserItem] = []
    @State private var browserIndex = 0
    @State private var browserStatus: String?
    @State private var includeArchived = false

    private enum BrowserKind { case sessions, models, profiles, edits, search }
    private struct BrowserItem: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    init(
        initialModel: String,
        endpoint: String,
        apiKeyEnvironment: String,
        initialEffort: ReasoningEffort?,
        maximumTokens: Int,
        contextWindowTokens: Int,
        contextSafetyReserveTokens: Int,
        contextCompactAtPercent: Int,
        contextStrategy: ContextStrategy,
        systemPrompt: String?,
        audioOutputDirectory: String,
        startupError: String?,
        workspacePath: String,
        sessionsDirectory: String?,
        resumeSelector: String?
    ) {
        self.initialModel = initialModel
        _endpoint = State(initialValue: endpoint)
        _apiKeyEnvironment = State(initialValue: apiKeyEnvironment)
        _reasoningEffort = State(initialValue: initialEffort)
        _maximumTokens = State(initialValue: maximumTokens)
        _contextWindowTokens = State(initialValue: contextWindowTokens)
        _contextSafetyReserveTokens = State(initialValue: contextSafetyReserveTokens)
        _contextCompactAtPercent = State(initialValue: contextCompactAtPercent)
        _contextStrategy = State(initialValue: contextStrategy)
        _systemPrompt = State(initialValue: systemPrompt)
        _workspacePath = State(initialValue: URL(fileURLWithPath: NSString(string: workspacePath)
            .expandingTildeInPath).standardizedFileURL.path)
        self.store = ConversationStore(directory: sessionsDirectory.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        })
        self.resumeSelector = resumeSelector
        _audioOutputDirectory = State(initialValue: audioOutputDirectory)
        self.startupError = startupError
        _modelPath = State(initialValue: initialModel)
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 0) {
            transcriptView(width: geometry.size.width, height: geometry.size.height)
            if let saveError { Text(saveError).foregroundStyle(LowlightPalette.danger).padding(.horizontal, 1) }
            composer(width: geometry.size.width)
            if browser != nil && !confirmingExit { browserPicker(width: geometry.size.width) }
            else if choosingSkills && !confirmingExit { skillPicker }
            else if !visibleSlashCommands.isEmpty && !confirmingExit { commandSuggestions(width: geometry.size.width) }
            else { footer(width: geometry.size.width) }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        }
        .background(Color.white)
        .foregroundStyle(LowlightPalette.ink)
        .environment(\.terminalAppearance, LowlightPalette.appearance)
        .onChange(of: draft) {
            confirmingExit = false
            commandChoiceIndex = 0
            if dismissedCommandDraft != draft { dismissedCommandDraft = nil }
            if browser != nil {
                browserIndex = 0
                if browser == .sessions { refreshSessionBrowser() }
            }
            scheduleDraftSave()
        }
        .onChange(of: pendingAttachments) { scheduleDraftSave() }
        .onAppear {
            guard !didAutoload else { return }
            didAutoload = true
            if let startupError {
                phase = .error
                status = startupError
                promptIsFocused = false
                return
            }
            if let resumeSelector {
                resumeConversation(resumeSelector)
            } else if !initialModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadModel()
            } else {
                promptIsFocused = true
            }
        }
        .onDisappear {
            draftSaveTask?.cancel()
            _ = persistConversation()
            generationTask?.cancel()
            elapsedTimeTask?.cancel()
            clearTask?.cancel()
            connectionTask?.cancel()
            let activeSession = session
            Task { await activeSession?.shutdown() }
        }
        .onKeyPress(.escape) { _ in
            if confirmingExit { confirmingExit = false; return .handled }
            if editingSystem {
                editingSystem = false
                promptIsFocused = true
                return .handled
            }
            guard phase == .generating || phase == .synthesizing else { return .ignored }
            stopGeneration()
            return .handled
        }
        .onKeyPress(.character("c"), modifiers: .ctrl) { _ in
            confirmExit()
            return .handled
        }
        .onKeyPress(.character("d"), modifiers: .ctrl) { _ in
            exitChat()
            return .handled
        }
        .onKeyPress(.pageUp) { _ in
            followsTranscript = false
            return .ignored
        }
        .onKeyPress(.character("f"), modifiers: .ctrl) { _ in
            followsTranscript.toggle()
            return .handled
        }
    }

    private var displayWorkspace: String {
        workspacePath
    }

    private func header(width: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                Text(LowlightBrand.mark).foregroundStyle(LowlightPalette.blue)
                Text("lowlight").bold().foregroundStyle(LowlightPalette.accent)
                if appMode == .tts { Text("/ speech").foregroundStyle(LowlightPalette.muted) }
                Spacer(minLength: 1)
                Text(conversationTitle).foregroundStyle(LowlightPalette.muted).lineLimit(1)
            }
            Text("\(displayWorkspace)  ·  \(activeModelLabel)")
                .foregroundStyle(LowlightPalette.muted).lineLimit(1)
        }
        .padding(.horizontal, 2).padding(.vertical, 1)
    }

    private func transcriptView(width: Int, height: Int) -> some View {
        let lineWidth = max(10, width - 6)
        let rows = transcript.messages.reduce(0) { count, message in
            let thinking = message.reasoning ?? ""
            let thinkingRows = thinking.isEmpty ? 0 : 2 + (showThinking
                ? thinking.components(separatedBy: "\n").reduce(0) { $0 + max(1, ($1.count + lineWidth - 1) / lineWidth) } : 0)
            return count + thinkingRows + 1 + message.text.components(separatedBy: "\n").reduce(0) {
                $0 + max(1, ($1.count + lineWidth - 1) / lineWidth)
            }
        }
        let extra = browser != nil ? min(6, filteredBrowserItems.count) + 3
            : choosingSkills ? min(6, skillChoices.count) + 4
            : visibleSlashCommands.isEmpty ? 2 : min(Self.commandMenuRows, visibleSlashCommands.count) + 2
        let available = max(3, height - composerRows(width: width) - 2 - extra - (pendingAttachments.isEmpty ? 0 : 1) - (saveError == nil ? 0 : 1))
        let contentHeight = transcript.messages.isEmpty ? 15 : 7 + rows
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    header(width: width)
                    if transcript.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(transcript.messages, id: \.id) { message in
                            TranscriptRow(
                                message: message,
                                elapsedSeconds: generationElapsedSeconds,
                                showThinking: showThinking
                            ).id(message.id)
                        }
                    }
                    Text(" ").id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .frame(height: min(available, contentHeight))
            .onChange(of: transcript.messages) {
                if followsTranscript { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: scrollTarget) {
                if let scrollTarget { proxy.scrollTo(scrollTarget, anchor: .top) }
            }
            .onChange(of: followsTranscript) {
                if followsTranscript { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch phase {
            case .error:
                Text("! \(status)").foregroundStyle(LowlightPalette.danger)
                if startupError == nil {
                    Text("Offline · \(endpoint). Use /set endpoint-url URL to change it.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Fix the settings file and restart lowlight.")
                        .foregroundStyle(.secondary)
                }
            case .configured:
                Text("bring your model. keep the conversation.").foregroundStyle(LowlightPalette.muted)
                Text("Tip: Chats save automatically. Use /resume last to pick up where you left off.")
                    .foregroundStyle(.secondary)
            case .connecting, .clearing:
                LoadingProgressView(label: status)
            case .idle, .generating, .synthesizing:
                Text("Connect to a model endpoint.")
                Text("Use /model NAME to connect, or /resume last to continue a saved chat.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(1)
    }

    private func commandSuggestions(width: Int) -> some View {
        let commands = visibleSlashCommands
        let selected = min(commandChoiceIndex, max(0, commands.count - 1))
        let start = max(0, selected - Self.commandMenuRows + 1)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()).dropFirst(start).prefix(Self.commandMenuRows), id: \.element.id) { index, command in
                HStack(spacing: 1) {
                    Text(index == selected ? ">" : " ")
                        .foregroundStyle(LowlightPalette.accent)
                    Text(String(command.usage.dropFirst()))
                        .foregroundStyle(index == selected ? LowlightPalette.accent : LowlightPalette.muted)
                        .frame(width: max(12, min(46, width / 2 - 4)), alignment: .leading)
                        .lineLimit(1)
                    Text(command.description)
                        .foregroundStyle(index == selected ? LowlightPalette.accent : LowlightPalette.muted)
                }.lineLimit(1)
            }
            Text(" ")
            HStack(spacing: 2) {
                Text("(\(selected + 1)/\(commands.count))").foregroundStyle(LowlightPalette.muted)
                Text("↑↓ select · tab complete · enter choose · esc close")
                    .foregroundStyle(LowlightPalette.muted).lineLimit(1)
            }
        }.padding(.horizontal, 2)
    }

    private var skillPicker: some View {
        let start = max(0, skillChoiceIndex - 5)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Skills · \(chosenSkillNames.count) selected").bold().foregroundStyle(LowlightPalette.accent)
            if skillChoices.isEmpty {
                Text("No skills found in this workspace. Add .midnight/skills/NAME/SKILL.md.").foregroundStyle(.secondary)
            }
            ForEach(Array(skillChoices.enumerated()).dropFirst(start).prefix(6), id: \.element.name) { index, skill in
                HStack(spacing: 1) {
                    Text(index == skillChoiceIndex ? "›" : " ").foregroundStyle(LowlightPalette.accent)
                    Text(chosenSkillNames.contains(skill.name) ? "[✓]" : "[ ]").foregroundStyle(LowlightPalette.accent)
                    Text(skill.name).foregroundStyle(index == skillChoiceIndex ? LowlightPalette.accent : LowlightPalette.muted)
                    Text(skill.description).foregroundStyle(.secondary)
                }.lineLimit(1)
            }
            if let skillPickerError { Text(skillPickerError).foregroundStyle(LowlightPalette.detailAccent).lineLimit(1) }
            Text("↑↓ move · space toggle · enter apply · esc cancel").foregroundStyle(.secondary)
        }.padding(.horizontal, 2).padding(.vertical, 1)
    }

    private func openSkillPicker() {
        let catalog = SkillLibrary(workspace: URL(fileURLWithPath: workspacePath)).scan()
        skillChoices = catalog.skills
        for skill in activeSkills where !skillChoices.contains(where: { $0.name == skill.name }) {
            skillChoices.append(SkillSummary(name: skill.name, description: skill.description, sourcePath: skill.sourcePath))
        }
        chosenSkillNames = Set(activeSkills.map(\.name))
        skillChoiceIndex = 0
        skillPickerError = catalog.warnings.first
        choosingSkills = true
    }

    private func manageSkills(_ argument: String?) {
        guard let argument else { openSkillPicker(); return }
        let parts = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let action = String(parts[0])
        let name = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let library = SkillLibrary(workspace: URL(fileURLWithPath: workspacePath))
        switch action {
        case "list" where name == nil:
            let catalog = library.scan()
            let rows = catalog.skills.map { skill in
                "\(activeSkills.contains(where: { $0.name == skill.name }) ? "✓" : "○") \(skill.name) — \(skill.description)"
            }
            addCommandNotice((rows.isEmpty ? "No skills found. Create one with /skill create NAME." : rows.joined(separator: "\n"))
                + (catalog.warnings.isEmpty ? "" : "\n" + catalog.warnings.joined(separator: "\n")))
        case "create":
            guard let name else { addCommandNotice("Usage: /skill create NAME"); return }
            do {
                try library.validateNewName(name)
                guard !library.scan().skills.contains(where: { $0.name == name }) else {
                    addCommandNotice("Skill \(name) already exists. Select it with /skill use \(name)."); return
                }
                creatingSkillName = name
                instructionEditorError = nil
                systemDraft = "---\nname: \(name)\ndescription: Describe when to use this skill.\n---\n\n"
                editingSystem = true
            } catch { addCommandNotice(error.localizedDescription) }
        case "use":
            guard let name else { addCommandNotice("Usage: /skill use NAME"); return }
            skillCommand(name)
        case "off":
            guard let name else { addCommandNotice("Usage: /skill off NAME"); return }
            skillCommand("off " + name)
        case "clear" where name == nil:
            skillCommand("clear")
        default:
            addCommandNotice("Usage: /skill [list|create NAME|use NAME|off NAME|clear]")
        }
    }

    private func saveInstructionEditor() {
        guard let name = creatingSkillName else {
            applyInstructions(prompt: systemDraft, skills: activeSkills)
            return
        }
        do {
            let skill = try SkillLibrary(workspace: URL(fileURLWithPath: workspacePath)).create(name: name, markdown: systemDraft)
            creatingSkillName = nil
            editingSystem = false
            instructionEditorError = nil
            addCommandNotice("Created \(skill.sourcePath). Activate it with /skill use \(name).")
        } catch { instructionEditorError = error.localizedDescription }
    }

    private func applySkillSelection() {
        do {
            let library = SkillLibrary(workspace: URL(fileURLWithPath: workspacePath))
            let selected = try skillChoices.filter { chosenSkillNames.contains($0.name) }.map { choice in
                if let saved = activeSkills.first(where: { $0.name == choice.name }) { return saved }
                return try library.load(name: choice.name)
            }
            choosingSkills = false
            applyInstructions(prompt: systemPrompt, skills: selected)
        } catch { skillPickerError = error.localizedDescription }
    }

    private func composerRows(width: Int) -> Int {
        if editingSystem { return 8 }
        if browser != nil { return 1 }
        let columns = max(10, width - 5)
        return min(5, max(1, draft.components(separatedBy: "\n").reduce(0) {
            $0 + max(1, ($1.count + columns - 1) / columns)
        }))
    }

    private func composer(width: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pendingAttachments.isEmpty {
                Text("Attached: \(pendingAttachments.map(\.name).joined(separator: ", ")) · ≈\(pendingAttachments.reduce(0) { $0 + $1.estimatedTokens }) tokens · /attach to manage")
                    .foregroundStyle(LowlightPalette.muted).lineLimit(1)
            }
            if editingSystem {
                Text(creatingSkillName.map { "Create skill: \($0) · Ctrl-S save · Esc cancel" }
                     ?? "System prompt · Ctrl-S apply · Esc cancel")
                    .foregroundStyle(LowlightPalette.detailAccent)
                if let instructionEditorError { Text(instructionEditorError).foregroundStyle(LowlightPalette.danger) }
                TextEditor(text: $systemDraft)
                    .focused($promptIsFocused)
                    .onKeyPress(.character("s"), modifiers: .ctrl) { _ in
                        saveInstructionEditor()
                        return .handled
                    }
                    .onKeyPress(.escape) { _ in
                        editingSystem = false
                        creatingSkillName = nil
                        promptIsFocused = true
                        return .handled
                    }
                    .onKeyPress(.character("d"), modifiers: .ctrl) { _ in exitChat(); return .handled }
                    .onKeyPress(.character("c"), modifiers: .ctrl) { _ in confirmExit(); return .handled }
                    .frame(height: 8)
                    .task {
                        promptIsFocused = false
                        await Task.yield()
                        promptIsFocused = true
                    }
            } else {
                HStack(alignment: .center, spacing: 1) {
                Text(">").foregroundStyle(LowlightPalette.blue)
                TextEditor(text: $draft)
                    .focused($promptIsFocused)
                    .onKeyPress(.return) { _ in
                        if browser != nil {
                            chooseBrowserItem()
                        } else if choosingSkills {
                            applySkillSelection()
                        } else if let selectedCommand, draft.lowercased() != selectedCommand.name {
                            _ = completeSlashCommand()
                        } else {
                            submitPrompt()
                        }
                        return .handled
                    }
                    .onKeyPress(.return, modifiers: .shift) { _ in .ignored }
                    .onKeyPress(.character("n"), modifiers: .ctrl) { _ in
                        if browser == nil { draft += "\n" }
                        return .handled
                    }
                    .onKeyPress(.arrowUp) { _ in
                        if browser != nil { browserIndex = max(0, browserIndex - 1); return .handled }
                        if choosingSkills { skillChoiceIndex = max(0, skillChoiceIndex - 1); return .handled }
                        if !visibleSlashCommands.isEmpty {
                            commandChoiceIndex = max(0, commandChoiceIndex - 1); return .handled
                        }
                        return draft.contains("\n") ? .ignored : recallPreviousInput()
                    }
                    .onKeyPress(.arrowDown) { _ in
                        if browser != nil {
                            browserIndex = min(max(0, filteredBrowserItems.count - 1), browserIndex + 1); return .handled
                        }
                        if choosingSkills { skillChoiceIndex = min(max(0, skillChoices.count - 1), skillChoiceIndex + 1); return .handled }
                        if !visibleSlashCommands.isEmpty {
                            commandChoiceIndex = min(visibleSlashCommands.count - 1, commandChoiceIndex + 1); return .handled
                        }
                        return draft.contains("\n") ? .ignored : recallNextInput()
                    }
                    .onKeyPress(.tab) { _ in completeSlashCommand() }
                    .onKeyPress(.space) { _ in
                        guard choosingSkills, !skillChoices.isEmpty else { return .ignored }
                        let name = skillChoices[skillChoiceIndex].name
                        if chosenSkillNames.contains(name) { chosenSkillNames.remove(name) }
                        else { chosenSkillNames.insert(name) }
                        return .handled
                    }
                    .onKeyPress(.escape) { _ in
                        if confirmingExit { confirmingExit = false; return .handled }
                        if browser != nil { closeBrowser(); return .handled }
                        if choosingSkills { choosingSkills = false; return .handled }
                        if !visibleSlashCommands.isEmpty { dismissedCommandDraft = draft; return .handled }
                        guard generationTask != nil || connectionTask != nil else { return .ignored }
                        stopGeneration(); return .handled
                    }
                    .onKeyPress(.character("c"), modifiers: .ctrl) { _ in
                        confirmExit()
                        return .handled
                    }
                    .onKeyPress(.character("d"), modifiers: .ctrl) { _ in exitChat(); return .handled }
                    .onKeyPress(.character("f"), modifiers: .ctrl) { _ in
                        followsTranscript.toggle(); return .handled
                    }
                    .onKeyPress(.character("t"), modifiers: .ctrl) { _ in
                        showThinking.toggle(); return .handled
                    }
                    .onKeyPress(.pageUp) { _ in followsTranscript = false; return .ignored }
                    .focusEffectDisabled()
                    .frame(height: composerRows(width: width) + 2)
                    .frame(maxWidth: .infinity)
                    .border(.background, sides: [.leading, .trailing])
                    .overlay(alignment: .leading) {
                        if (browser == nil ? draft : browserQuery).isEmpty {
                            Text(browser != nil ? " Type to filter…" : (choosingSkills ? " Select skills below" : " Type your message, or / for commands"))
                                .foregroundStyle(.secondary).padding(.leading, 1).allowsHitTesting(false)
                        }
                    }
                    .task {
                        promptIsFocused = false
                        await Task.yield()
                        promptIsFocused = true
                    }
                }
                .overlay(alignment: .top) {
                    Text(String(repeating: "─", count: max(1, width - 2)))
                        .foregroundStyle(LowlightPalette.blue).allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    Text(String(repeating: "─", count: max(1, width - 2)))
                        .foregroundStyle(LowlightPalette.blue).allowsHitTesting(false)
                }
            }
        }.padding(.horizontal, 1)
    }

    private func footer(width: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                Text("➜ \(displayWorkspace) · \(activeModelLabel)").foregroundStyle(LowlightPalette.accent).lineLimit(1)
                Text("· effort \(reasoningEffort?.rawValue ?? "default")").foregroundStyle(LowlightPalette.detailAccent)
                if !activeSkills.isEmpty { Text("· \(activeSkills.count) \(activeSkills.count == 1 ? "skill" : "skills")").foregroundStyle(LowlightPalette.muted) }
            }
        HStack(spacing: 1) {
            Text(footerHint).foregroundStyle(.secondary)
            Spacer(minLength: 1)
            if width >= 72, let contextSnapshot {
                Text(
                    "ctx ≈\(compactTokenCount(contextSnapshot.estimatedInputTokens))"
                        + "/\(compactTokenCount(contextSnapshot.inputBudgetTokens))"
                )
                .foregroundStyle(LowlightPalette.accent)
            }
            if width >= 100, let rate = lastPerformance?.tokensPerSecond {
                Text("• \(formattedRate(rate)) tok/s")
                    .foregroundStyle(LowlightPalette.accent)
            }
            Text(phase.label).foregroundStyle(phase.color)
            if appMode == .tts { Text("TTS").foregroundStyle(LowlightPalette.detailAccent) }
            if contextSnapshot?.hasSummary == true { Text("checkpoint").foregroundStyle(LowlightPalette.muted) }
            if !followsTranscript { Text("paused · ctrl-f follow").foregroundStyle(LowlightPalette.detailAccent) }
        }
        .lineLimit(1)
        }.padding(.horizontal, 2)
    }

    private var isBusy: Bool {
        phase == .connecting || phase == .clearing || phase == .generating
            || phase == .synthesizing
    }

    private var visibleSlashCommands: [SlashCommand] {
        let query = draft.lowercased()
        guard browser == nil, !editingSystem, !choosingSkills, dismissedCommandDraft != draft,
              query.hasPrefix("/"), !query.contains(where: \.isWhitespace) else { return [] }

        let availableCommands = session == nil
            ? Self.slashCommands.filter { $0.name != "/context" && $0.name != "/usage" }
            : Self.slashCommands
        return availableCommands.filter { $0.name.hasPrefix(query) }
    }

    private var selectedCommand: SlashCommand? {
        let commands = visibleSlashCommands
        guard !commands.isEmpty else { return nil }
        return commands[min(commandChoiceIndex, commands.count - 1)]
    }

    private var footerHint: String {
        if confirmingExit { return "Press Ctrl-C again to save and exit · Esc to cancel" }
        if editingSystem {
            return "ctrl-s apply  ·  esc cancel"
        }
        if startupError != nil {
            return "configuration error  •  /exit"
        }
        if phase == .connecting {
            return "checking endpoint  •  /exit"
        }
        if session == nil {
            return "enter send  ·  /help"
        }
        if phase == .generating || phase == .synthesizing {
            return "\(status)  ·  esc stop"
        }
        if phase == .clearing {
            return status
        }
        return "enter send  ·  ctrl-n newline  ·  ? help"
    }

    private var availableModelsSummary: String {
        guard !availableModels.isEmpty else { return "Endpoint connected; no models reported." }
        return "Available models: \(availableModels.joined(separator: ", "))"
    }

    private func confirmExit() {
        if confirmingExit { exitChat(); return }
        if isBusy { stopGeneration() }
        confirmingExit = true
    }

    private var modelName: String {
        let path = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "no model" : path
    }

    private var activeModelLabel: String {
        switch appMode {
        case .chat: modelName
        case .tts: "\(ttsModel) • \(ttsVoice)"
        }
    }

    private func loadModel() {
        let requestedPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard startupError == nil, !requestedPath.isEmpty, !isBusy else { return }
        connectionTask?.cancel()
        let previousSession = session
        session = nil
        modelCatalog = []
        availableModels = []
        lastPerformance = nil
        phase = .connecting
        status = "Connecting…"
        connectionTask = Task { @MainActor in
            defer {
                connectionTask = nil
                promptIsFocused = true
            }
            await previousSession?.shutdown()
            do {
                let connected = try EndpointModelSession(
                    model: requestedPath, endpoint: endpoint, apiKey: apiKey,
                    maximumTokens: maximumTokens, contextWindowTokens: contextWindowTokens,
                    contextSafetyReserveTokens: contextSafetyReserveTokens,
                    contextCompactAtPercent: contextCompactAtPercent,
                    contextStrategy: contextStrategy,
                    systemPrompt: composeSystemPrompt(base: systemPrompt, skills: activeSkills)
                )
                contextSnapshot = try await connected.restoreContext(savedContext)
                do {
                    modelCatalog = try await connected.modelCatalog()
                } catch EndpointSessionError.httpStatus(let code) where code == 404 || code == 405 {
                    modelCatalog = []
                    addCommandNotice("This endpoint does not provide a model list. Using the explicitly selected model; capabilities are unknown.")
                }
                availableModels = modelCatalog.map(\.id)
                try Task.checkCancellation()
                session = connected
                modelPath = connected.modelPath
                phase = .configured
                status = "Connected."
                _ = persistConversation()
                if !capabilityIssues.isEmpty { addCommandNotice(capabilityIssues.joined(separator: "\n")) }
                if !availableModels.isEmpty && !availableModels.contains(requestedPath) {
                    addCommandNotice("Model \(requestedPath) is not in the server's list. Use /model to choose one.")
                }
                if retryAfterConnect {
                    retryAfterConnect = false
                    Task { @MainActor in
                        await Task.yield()
                        guard self.session === connected else { return }
                        sendChat()
                    }
                }
            } catch is CancellationError {
                retryAfterConnect = false
                phase = .idle
                status = "Connection cancelled."
            } catch {
                phase = .error
                retryAfterConnect = false
                status = ConnectionDiagnostics.describe(error, endpoint: endpoint, apiKeyEnvironment: apiKeyEnvironment)
                if !transcript.messages.isEmpty { transcript.addNotice("Connection: " + status) }
            }
        }
    }

    private func completeSlashCommand() -> KeyPressResult {
        guard let command = selectedCommand else { return .ignored }
        let completion = [.mode, .resume].contains(command)
            ? "\(command.name) "
            : command.name
        draft = completion
        dismissedCommandDraft = completion
        return .handled
    }

    private func submitPrompt() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if prompt == "?" { draft = ""; showHelp(); return }
        if prompt.lowercased() == "/exit" { draft = ""; exitChat(); return }
        guard !isBusy else { return }
        rememberInput(prompt)
        guard !handleSlashCommand(prompt) else { return }
        guard session != nil else {
            addCommandNotice("Connect with /model NAME or /set endpoint-url URL before sending a message.")
            return
        }
        switch appMode {
        case .chat: sendChat()
        case .tts:
            if pendingAttachments.isEmpty { sendSpeech() }
            else { addCommandNotice("Attachments are for chat. Use /mode chat or /attach clear.") }
        }
    }

    private func rememberInput(_ input: String) {
        historyIndex = nil
        draftBeforeHistory = ""
        let commandParts = input.split(whereSeparator: \.isWhitespace).prefix(2).map { $0.lowercased() }
        guard !input.isEmpty, inputHistory.last != input,
              commandParts != ["/set", "endpoint-url"] else { return }
        inputHistory.append(input)
    }

    private func recallPreviousInput() -> KeyPressResult {
        guard !inputHistory.isEmpty else { return .ignored }
        if historyIndex == nil {
            draftBeforeHistory = draft
            historyIndex = inputHistory.count - 1
        } else if let historyIndex, historyIndex > 0 {
            self.historyIndex = historyIndex - 1
        }
        applyHistorySelection()
        return .handled
    }

    private func recallNextInput() -> KeyPressResult {
        guard let historyIndex else { return .ignored }
        if historyIndex < inputHistory.count - 1 {
            self.historyIndex = historyIndex + 1
            applyHistorySelection()
        } else {
            self.historyIndex = nil
            setComposerText(draftBeforeHistory)
            draftBeforeHistory = ""
        }
        return .handled
    }

    private func applyHistorySelection() {
        guard let historyIndex else { return }
        setComposerText(inputHistory[historyIndex])
    }

    private func setComposerText(_ text: String) { draft = text }

    private static func parseSlashCommand(_ input: String) -> ParsedSlashCommand? {
        guard input.hasPrefix("/") else { return nil }

        let components = input.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard let commandText = components.first else {
            return .invalid(message: "Unknown command. Type / to see available commands.")
        }

        let commandName = commandText.lowercased()
        guard let command = SlashCommand(rawValue: commandName) else {
            return .invalid(
                message: "Unknown command \(commandText). Type / to see available commands."
            )
        }

        let argument = components.count == 2
            ? String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        switch command {
        case .clear:
            guard argument == nil else {
                return .invalid(message: "Usage: \(command.usage)")
            }
            return .clear
        case .context:
            guard argument == nil else {
                return .invalid(message: "Usage: \(command.usage)")
            }
            return .context
        case .help:
            guard argument == nil else {
                return .invalid(message: "Usage: \(command.usage)")
            }
            return .help
        case .model:
            return .model(name: argument ?? "")
        case .mode:
            guard let argument,
                  let mode = AppMode(rawValue: argument.lowercased())
            else {
                return .invalid(message: "Usage: \(command.usage)")
            }
            return .mode(mode)
        case .quit:
            guard argument == nil else {
                return .invalid(message: "Usage: \(command.usage)")
            }
            return .quit
        case .new, .save, .sessions, .resume, .system, .skills, .compact, .effort,
             .attach, .retry, .edit, .branch, .search, .export, .profile, .connection:
            return .local(command, argument)
        case .set:
            return .set(argument: argument)
        case .usage:
            guard argument == nil else {
                return .invalid(message: "Usage: \(command.usage)")
            }
            return .usage
        }
    }

    @discardableResult
    private func handleSlashCommand(_ input: String) -> Bool {
        guard let command = Self.parseSlashCommand(input) else { return false }

        if case .quit = command {
            exitChat()
            return true
        }

        guard !isBusy else { return true }

        switch command {
        case .quit:
            break
        case .clear:
            clearComposer()
            newConversation(title: nil)
        case .context:
            clearComposer()
            guard session != nil else {
                addCommandNotice("Context is unavailable until a model is selected. Use /model MODEL.")
                return true
            }
            showContext()
        case .help:
            clearComposer()
            showHelp()
        case let .model(name):
            clearComposer()
            if name.isEmpty { openModelBrowser() }
            else { modelPath = name; loadModel() }
        case let .mode(mode):
            clearComposer()
            appMode = mode
            addCommandNotice("Mode changed to \(mode.label).")
        case let .set(argument):
            setSetting(argument)
        case .usage:
            clearComposer()
            guard session != nil else {
                addCommandNotice("Usage is unavailable until a model is selected. Use /model MODEL.")
                return true
            }
            showUsage()
        case let .local(command, argument):
            clearComposer()
            handleLocalCommand(command, argument: argument)
            _ = persistConversation()
        case let .invalid(message):
            clearComposer()
            addCommandNotice(message)
        }
        return true
    }

    private func showHelp() {
        let commands = Self.slashCommands
            .map { "\($0.usage) — \($0.description)" }
            .joined(separator: "\n")
        addCommandNotice(
            "\(commands)\n\nEnter sends · Ctrl-N adds a newline · Up/Down recalls single-line input · Tab completes\nEsc stops · Ctrl-C twice saves and exits · Ctrl-T toggles thinking · Ctrl-D saves and exits · Ctrl-F toggles transcript following"
        )
    }

    private func clearComposer() { draft = "" }

    private func addCommandNotice(_ message: String) {
        followsTranscript = true
        transcript.addNotice(message)
        status = message
        promptIsFocused = true
    }

    private var effectiveSystemPrompt: String? {
        composeSystemPrompt(base: systemPrompt, skills: activeSkills)
    }

    private func conversationSnapshot() -> SavedConversation {
        SavedConversation(
            id: conversationID, title: conversationTitle,
            createdAt: conversationCreatedAt, updatedAt: Date(),
            model: modelName, endpoint: endpoint, workspacePath: workspacePath,
            maximumTokens: maximumTokens, contextWindowTokens: contextWindowTokens,
            contextSafetyReserveTokens: contextSafetyReserveTokens,
            contextCompactAtPercent: contextCompactAtPercent,
            contextStrategy: contextStrategy, systemPrompt: systemPrompt,
            activeSkills: activeSkills, context: savedContext,
            transcript: transcript, inputHistory: inputHistory,
            reasoningEffort: reasoningEffort, draft: conversationDraft.isEmpty ? nil : conversationDraft,
            pendingAttachments: pendingAttachments.isEmpty ? nil : pendingAttachments,
            archived: conversationArchived ? true : nil, parentID: parentConversationID,
            apiKeyEnvironment: apiKeyEnvironment
        )
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = persistConversation()
        }
    }

    @discardableResult
    private func persistConversation(force: Bool = false) -> Bool {
        guard force || !transcript.messages.isEmpty || !conversationDraft.isEmpty || !pendingAttachments.isEmpty
            || FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("\(conversationID.uuidString).json").path)
        else { return true }
        do {
            _ = try store.save(conversationSnapshot())
            saveError = nil
            return true
        } catch {
            saveError = "Not saved: \(error.localizedDescription)"
            status = saveError ?? "Could not save."
            return false
        }
    }

    private func handleLocalCommand(_ command: SlashCommand, argument: String?) {
        switch command {
        case .effort:
            guard let argument else {
                addCommandNotice("Reasoning effort: \(reasoningEffort?.rawValue ?? "default"). Use /effort low|medium|high|default.")
                return
            }
            guard !isBusy else { addCommandNotice("Stop the current generation before changing effort."); return }
            let value = argument.lowercased()
            guard value == "default" || ReasoningEffort(rawValue: value) != nil else {
                addCommandNotice("Usage: /effort low|medium|high|default"); return
            }
            reasoningEffort = ReasoningEffort(rawValue: value)
            addCommandNotice("Reasoning effort: \(value). Applies to the next request if supported by the endpoint.")
        case .save:
            if let argument { conversationTitle = String(argument.prefix(200)) }
            if persistConversation(force: true) {
                addCommandNotice("Saved \(conversationTitle) · \(conversationID.uuidString.prefix(8).lowercased())")
            } else { addCommandNotice(saveError ?? "Save failed.") }
        case .sessions:
            manageSessions(argument)
        case .attach: manageAttachments(argument)
        case .retry: reviseTurn(argument, retry: true)
        case .edit: reviseTurn(argument, retry: false)
        case .branch: branchConversation(argument)
        case .search: searchTranscript(argument)
        case .export: exportConversation(argument)
        case .profile: manageProfiles(argument)
        case .connection:
            if argument == "reconnect" { loadModel() }
            else if argument == nil { addCommandNotice(connectionDescription) }
            else { addCommandNotice("Usage: /connection [reconnect]") }
        case .resume:
            guard let argument else { addCommandNotice("Usage: /resume ID|last"); return }
            resumeConversation(argument)
        case .new:
            newConversation(title: argument)
        case .system:
            systemCommand(argument)
        case .skills:
            manageSkills(argument)
        case .compact:
            compactConversation(guidance: argument)
        default: break
        }
    }

    private func resumeConversation(_ selector: String) {
        guard !isBusy else { return }
        do {
            // Resolve first: saving the current chat must not change what 'last' means.
            let saved = try store.load(selector)
            guard persistConversation() else { addCommandNotice(saveError ?? "Save failed."); return }
            activateConversation(saved)
        } catch { addCommandNotice(error.localizedDescription) }
    }

    private func activateConversation(_ saved: SavedConversation) {
        draftSaveTask?.cancel()
        browser = nil
        choosingSkills = false
        let previous = session
        session = nil
        Task { await previous?.shutdown() }
        conversationID = saved.id
        conversationTitle = saved.title
        conversationCreatedAt = saved.createdAt
        modelPath = saved.model
        endpoint = saved.endpoint
        workspacePath = saved.workspacePath
        maximumTokens = saved.maximumTokens
        reasoningEffort = saved.reasoningEffort
        contextWindowTokens = saved.contextWindowTokens
        contextSafetyReserveTokens = saved.contextSafetyReserveTokens
        contextCompactAtPercent = saved.contextCompactAtPercent
        contextStrategy = saved.contextStrategy
        systemPrompt = saved.systemPrompt
        activeSkills = saved.activeSkills
        savedContext = saved.context
        transcript = saved.transcript
        inputHistory = saved.inputHistory
        historyIndex = nil
        draft = saved.draft ?? ""
        pendingAttachments = saved.pendingAttachments ?? []
        conversationArchived = saved.archived == true
        parentConversationID = saved.parentID
        apiKeyEnvironment = saved.apiKeyEnvironment ?? apiKeyEnvironment
        editingSystem = false
        appMode = .chat
        followsTranscript = true
        phase = .idle
        saveError = nil
        addCommandNotice("Opened \(saved.title)." + (draft.isEmpty ? "" : " Unsent draft restored."))
        loadModel()
    }

    private func newConversation(title: String?) {
        guard !isBusy else { return }
        guard persistConversation() else { addCommandNotice(saveError ?? "Save failed."); return }
        let previous = session
        session = nil
        Task { await previous?.shutdown() }
        draftSaveTask?.cancel()
        conversationID = UUID()
        pendingAttachments = []
        conversationArchived = false
        parentConversationID = nil
        conversationTitle = title.map { String($0.prefix(200)) } ?? "New conversation"
        conversationCreatedAt = Date()
        savedContext = .init()
        transcript = .init()
        inputHistory = []
        historyIndex = nil
        contextSnapshot = nil
        draft = ""
        followsTranscript = true
        // Prompt and explicitly selected skills remain useful defaults for the next chat.
        phase = .idle
        loadModel()
    }

    private func systemCommand(_ argument: String?) {
        let parts = (argument ?? "show").split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let action = parts.first?.lowercased() ?? "show"
        let value = parts.count == 2 ? String(parts[1]) : nil
        switch action {
        case "show":
            guard value == nil else { addCommandNotice("Usage: /system show"); return }
            addCommandNotice("System prompt:\n\(systemPrompt ?? "(none)")\nActive skills: "
                + (activeSkills.isEmpty ? "none" : activeSkills.map(\.name).joined(separator: ", ")))
        case "edit":
            creatingSkillName = nil
            instructionEditorError = nil
            guard value == nil else { addCommandNotice("Usage: /system edit"); return }
            systemDraft = systemPrompt ?? ""
            editingSystem = true
            promptIsFocused = true
        case "clear":
            guard value == nil else { addCommandNotice("Usage: /system clear"); return }
            applyInstructions(prompt: nil, skills: activeSkills)
        case "set":
            guard let value, !value.isEmpty else { addCommandNotice("Usage: /system set TEXT"); return }
            applyInstructions(prompt: value, skills: activeSkills)
        case "file":
            guard let value else { addCommandNotice("Usage: /system file PATH"); return }
            do {
                let expanded = NSString(string: value).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workspacePath, isDirectory: true))
                applyInstructions(prompt: try readInstructionFile(url.path), skills: activeSkills)
            } catch { addCommandNotice(error.localizedDescription) }
        default:
            addCommandNotice("Usage: /system show|edit|set TEXT|file PATH|clear")
        }
    }

    private func skillCommand(_ argument: String?) {
        guard let argument else {
            addCommandNotice("Active skills: " + (activeSkills.isEmpty ? "none" : activeSkills.map(\.name).joined(separator: ", "))
                + "\nUsage: /skill use NAME | /skill off NAME | /skill clear")
            return
        }
        if argument == "clear" { applyInstructions(prompt: systemPrompt, skills: []); return }
        if argument.hasPrefix("off ") {
            let name = String(argument.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard activeSkills.contains(where: { $0.name == name }) else {
                addCommandNotice("Skill \(name) is not active."); return
            }
            applyInstructions(prompt: systemPrompt, skills: activeSkills.filter { $0.name != name })
            return
        }
        do {
            let skill = try SkillLibrary(workspace: URL(fileURLWithPath: workspacePath)).load(name: argument)
            applyInstructions(prompt: systemPrompt, skills: activeSkills.filter { $0.name != skill.name } + [skill])
        } catch { addCommandNotice(error.localizedDescription) }
    }

    private func applyInstructions(prompt: String?, skills: [SkillDocument]) {
        guard !isBusy else { return }
        phase = .clearing
        status = "Updating instructions…"
        clearTask = Task { @MainActor in
            defer { clearTask = nil; promptIsFocused = true }
            do {
                let effective = composeSystemPrompt(base: prompt, skills: skills)
                if let session {
                    contextSnapshot = try await session.updateSystemPrompt(effective)
                } else {
                    var manager = ContextWindowManager(policy: try ContextPolicy(
                        windowTokens: contextWindowTokens, maximumOutputTokens: maximumTokens,
                        safetyReserveTokens: contextSafetyReserveTokens, compactAtPercent: contextCompactAtPercent,
                        strategy: contextStrategy, systemPrompt: effectiveSystemPrompt
                    ), state: savedContext)
                    contextSnapshot = try manager.updateSystemPrompt(effective)
                }
                systemPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : prompt
                activeSkills = skills
                editingSystem = false
                phase = session == nil ? .idle : .configured
                addCommandNotice("Instructions updated for the next message. Conversation preserved.")
                _ = persistConversation(force: true)
            } catch {
                phase = session == nil ? .idle : .configured
                addCommandNotice(error.localizedDescription)
            }
        }
    }

    private func compactConversation(guidance: String?) {
        guard let session, !isBusy else {
            addCommandNotice("Connect to a model before creating a context summary."); return
        }
        phase = .generating
        status = "Compacting older context…"
        generationTask = Task { @MainActor in
            defer {
                generationTask = nil
                phase = .configured
                promptIsFocused = true
                _ = persistConversation()
            }
            do {
                contextSnapshot = try await session.compact(guidance: guidance)
                savedContext = await session.exportContext()
                addCommandNotice("Context checkpoint saved. The full conversation remains in the transcript.")
            } catch is CancellationError {
                addCommandNotice("Compaction stopped; previous context retained.")
            } catch {
                addCommandNotice("Compaction failed; previous context retained. \(error.localizedDescription)")
            }
        }
    }

    private func exitChat() {
        generationTask?.cancel()
        connectionTask?.cancel()
        let pendingGeneration = generationTask
        let pendingChange = clearTask
        Task { @MainActor in
            await pendingGeneration?.value
            await pendingChange?.value
            guard persistConversation() else {
                addCommandNotice(saveError ?? "Could not save. Fix the save directory and retry /save before exiting.")
                return
            }
            _ = requestTermination()
        }
    }

    private func setSetting(_ argument: String?) {
        guard let argument, !argument.isEmpty else {
            clearComposer()
            addCommandNotice(
                "Settings: endpoint-url=\(endpoint), context-window=\(contextWindowTokens), max-tokens=\(maximumTokens), api-key-env=\(apiKeyEnvironment), "
                    + "tts-model=\(ttsModel), voice=\(ttsVoice), audio-format=\(ttsFormat), "
                    + "audio-output-directory=\(audioOutputDirectory)."
            )
            return
        }

        let parts = argument.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard parts.count == 2 else {
            clearComposer()
            addCommandNotice(
                "Usage: /set endpoint-url URL | context-window TOKENS | max-tokens TOKENS | api-key-env NAME | "
                    + "tts-model MODEL | voice VOICE | audio-format FORMAT | "
                    + "audio-output-directory PATH"
            )
            return
        }

        let name = parts[0].lowercased()
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        var requiresReconnect = false
        switch name {
        case "endpoint-url":
            do { try validateChatEndpoint(value) }
            catch {
                clearComposer()
                addCommandNotice(error.localizedDescription)
                return
            }
            endpoint = value
            requiresReconnect = true
        case "context-window":
            guard let tokens = Int(value) else {
                clearComposer()
                addCommandNotice("Context window must be a whole number of tokens.")
                return
            }
            do {
                _ = try ContextPolicy(
                    windowTokens: tokens,
                    maximumOutputTokens: maximumTokens,
                    safetyReserveTokens: contextSafetyReserveTokens,
                    compactAtPercent: contextCompactAtPercent,
                    strategy: contextStrategy,
                    systemPrompt: systemPrompt
                )
            } catch {
                clearComposer()
                addCommandNotice(error.localizedDescription)
                return
            }
            contextWindowTokens = tokens
            requiresReconnect = true
        case "api-key-env":
            guard ConnectionProfile.validEnvironmentName(value) else {
                clearComposer(); addCommandNotice("Use an environment-variable name, not an API key."); return
            }
            apiKeyEnvironment = value
            requiresReconnect = true
        case "max-tokens":
            guard let tokens = Int(value), tokens > 0, tokens < contextWindowTokens - contextSafetyReserveTokens else {
                clearComposer(); addCommandNotice("Output tokens must be positive and fit inside the context window with the safety reserve."); return
            }
            maximumTokens = tokens
            requiresReconnect = true
        case "tts-model":
            guard !value.isEmpty else {
                clearComposer()
                addCommandNotice("TTS model cannot be empty.")
                return
            }
            ttsModel = value
        case "voice":
            guard !value.isEmpty else {
                clearComposer()
                addCommandNotice("Voice cannot be empty.")
                return
            }
            ttsVoice = value
        case "audio-format":
            let supportedFormats = ["mp3", "wav", "flac", "opus", "aac", "pcm"]
            guard supportedFormats.contains(value.lowercased()) else {
                clearComposer()
                addCommandNotice("Audio format must be mp3, wav, flac, opus, aac, or pcm.")
                return
            }
            ttsFormat = value.lowercased()
        case "audio-output-directory":
            guard !value.isEmpty else {
                clearComposer()
                addCommandNotice("Audio output directory cannot be empty.")
                return
            }
            audioOutputDirectory = value
        default:
            clearComposer()
            addCommandNotice(
                "Unknown setting \(parts[0]). Use /set to show available settings."
            )
            return
        }

        clearComposer()
        guard requiresReconnect else {
            addCommandNotice("Set \(name)=\(value).")
            return
        }
        _ = persistConversation()
        loadModel()
    }

    private func sendChat() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !prompt.isEmpty, !isBusy else { return }

        guard capabilityIssues.isEmpty else { addCommandNotice(capabilityIssues.joined(separator: "\n")); return }
        let attachments = pendingAttachments
        let wirePrompt = ChatAttachment.prompt(prompt, attachments: attachments)
        let oldTranscript = transcript
        let responseID = transcript.beginTurn(prompt: prompt, attachments: attachments)
        draft = ""
        pendingAttachments = []
        if conversationTitle == "New conversation" { conversationTitle = String(prompt.prefix(70)).replacingOccurrences(of: "\n", with: " ") }
        followsTranscript = true
        guard persistConversation() else {
            transcript = oldTranscript
            draft = prompt
            pendingAttachments = attachments
            return
        }
        phase = .generating
        status = "Generating…"
        generationElapsedSeconds = 0
        elapsedTimeTask?.cancel()
        elapsedTimeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                generationElapsedSeconds += 1
                if generationElapsedSeconds % 10 == 0, saveError == nil { _ = persistConversation() }
            }
        }

        generationTask = Task { @MainActor in
            defer {
                elapsedTimeTask?.cancel()
                elapsedTimeTask = nil
                generationTask = nil
                _ = persistConversation()
                promptIsFocused = true
            }
            do {
                let report = try await session.generate(responseTo: wirePrompt, reasoningEffort: reasoningEffort, onCompaction: { compacting in
                    status = compacting ? "Compacting older context…" : "Generating…"
                }, onReasoning: { chunk in
                    status = "Thinking…"
                    transcript.appendReasoning(chunk, to: responseID)
                }) { chunk in
                    status = "Answering…"
                    transcript.append(chunk, to: responseID)
                }
                transcript.finish(responseID: responseID)
                savedContext = await session.exportContext()
                contextSnapshot = report.context
                lastPerformance = await session.performanceSnapshot()
                if report.omittedTurns > 0 {
                    let noun = report.omittedTurns == 1 ? "turn" : "turns"
                    transcript.addNotice(
                        report.context.hasSummary
                            ? "Updated the conversation checkpoint; the full transcript is saved."
                            : "Omitted \(report.omittedTurns) older \(noun) from model context. The full transcript is saved."
                    )
                }
                phase = .configured
                status = "Configured."
            } catch is CancellationError {
                transcript.stop(responseID: responseID)
                phase = .configured
                status = "Generation stopped."
            } catch {
                transcript.fail(responseID: responseID, description: error.localizedDescription)
                phase = .error
                status = ConnectionDiagnostics.describe(error, endpoint: endpoint, apiKeyEnvironment: apiKeyEnvironment)
            }
        }
    }

    private func sendSpeech() {
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !input.isEmpty, !isBusy else { return }

        let responseID = transcript.beginTurn(prompt: input)
        if conversationTitle == "New conversation" { conversationTitle = String(input.prefix(70)).replacingOccurrences(of: "\n", with: " ") }
        followsTranscript = true
        guard persistConversation() else {
            transcript.fail(responseID: responseID, description: saveError ?? "Could not save this chat.")
            return
        }
        draft = ""
        phase = .synthesizing
        status = "Synthesizing speech…"
        generationElapsedSeconds = 0
        elapsedTimeTask?.cancel()
        elapsedTimeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                generationElapsedSeconds += 1
                if generationElapsedSeconds % 10 == 0, saveError == nil { _ = persistConversation() }
            }
        }

        generationTask = Task { @MainActor in
            defer {
                elapsedTimeTask?.cancel()
                elapsedTimeTask = nil
                generationTask = nil
                _ = persistConversation()
                promptIsFocused = true
            }
            do {
                let audio = try await session.synthesizeSpeech(
                    input: input,
                    model: ttsModel,
                    voice: ttsVoice,
                    responseFormat: ttsFormat
                )
                try Task.checkCancellation()
                let relativePath = try saveSpeechAudio(audio)
                transcript.append("Saved audio: \(relativePath)", to: responseID)
                transcript.finish(responseID: responseID)
                phase = .configured
                status = "Speech generated."
            } catch is CancellationError {
                transcript.stop(responseID: responseID)
                phase = .configured
                status = "Speech generation stopped."
            } catch {
                transcript.fail(responseID: responseID, description: error.localizedDescription)
                phase = .error
                status = error.localizedDescription
            }
        }
    }

    private func saveSpeechAudio(_ data: Data) throws -> String {
        let expandedPath = NSString(string: audioOutputDirectory).expandingTildeInPath
        let directory: URL
        if expandedPath.hasPrefix("/") {
            directory = URL(fileURLWithPath: expandedPath, isDirectory: true)
        } else {
            directory = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).appendingPathComponent(expandedPath, isDirectory: true)
        }
        let standardizedDirectory = directory.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardizedDirectory,
            withIntermediateDirectories: true
        )
        let identifier = UUID().uuidString.lowercased().prefix(8)
        let fileName = "speech-\(Int(Date().timeIntervalSince1970))-\(identifier).\(ttsFormat)"
        try data.write(to: standardizedDirectory.appendingPathComponent(fileName), options: .atomic)
        return standardizedDirectory.appendingPathComponent(fileName).path
    }

    private func stopGeneration() {
        if phase == .connecting {
            status = "Cancelling connection…"
            connectionTask?.cancel()
        } else if generationTask != nil {
            status = "Stopping…"
            generationTask?.cancel()
        }
    }

    private func showContext() {
        guard let session, !isBusy else { return }
        Task { @MainActor in
            let snapshot = await session.contextSnapshot()
            guard self.session === session else { return }
            contextSnapshot = snapshot
            addCommandNotice(contextDescription(snapshot))
            promptIsFocused = true
        }
    }

    private func formattedRate(_ rate: Double) -> String {
        String(format: "%.2f", rate)
    }

    private func showUsage() {
        guard let session, !isBusy else { return }
        Task { @MainActor in
            let snapshot = await session.usageSnapshot()
            guard self.session === session else { return }
            addCommandNotice(usageDescription(snapshot))
            promptIsFocused = true
        }
    }

    private func usageDescription(_ snapshot: UsageSnapshot) -> String {
        guard let last = snapshot.lastRequest else {
            return "No standard OpenAI usage has been reported yet. The configured context "
                + "window is \(snapshot.contextWindowTokens) tokens."
        }
        let requestLabel = snapshot.reportedRequests == 1 ? "request" : "requests"
        return "Last request: \(last.promptTokens) input + \(last.completionTokens) output "
            + "= \(last.totalTokens) tokens. Session total across \(snapshot.reportedRequests) "
            + "reported \(requestLabel): \(snapshot.promptTokens) input + "
            + "\(snapshot.completionTokens) output = \(snapshot.totalTokens) tokens. "
            + "Configured context window: \(snapshot.contextWindowTokens)."
    }

    private func contextDescription(_ snapshot: ContextSnapshot) -> String {
        let turnLabel = snapshot.activeTurns == 1 ? "turn" : "turns"
        var description =
            "Context ≈\(snapshot.estimatedInputTokens)/\(snapshot.inputBudgetTokens) input tokens "
            + "(window \(snapshot.windowTokens), output reserve "
            + "\(snapshot.maximumOutputTokens), safety \(snapshot.safetyReserveTokens), "
            + "manage at \(snapshot.compactAtPercent)%); "
            + "\(snapshot.activeTurns) active \(turnLabel)."
        if snapshot.hasSummary { description += " Checkpoint summary active." }
        if snapshot.totalOmittedTurns > 0 {
            description += " \(snapshot.totalOmittedTurns) older turns omitted so far."
        }
        return description
    }


    // Shared keyboard picker for local sessions, turns, profiles, and server models.
    private var filteredBrowserItems: [BrowserItem] {
        guard browser != .sessions, !browserQuery.isEmpty else { return browserItems }
        return browserItems.filter {
            $0.title.localizedCaseInsensitiveContains(browserQuery) || $0.detail.localizedCaseInsensitiveContains(browserQuery)
        }
    }

    private var browserTitle: String {
        switch browser {
        case .sessions: includeArchived ? "Sessions · including archived" : "Sessions"
        case .models: "Models from this endpoint"
        case .profiles: "Connection profiles"
        case .edits: "Choose a message to edit in a new branch"
        case .search: "Search results · choose to jump to a turn"
        case nil: ""
        }
    }

    private func browserPicker(width: Int) -> some View {
        let items = filteredBrowserItems
        let start = max(0, browserIndex - 5)
        return VStack(alignment: .leading, spacing: 0) {
            Text(browserTitle).bold().foregroundStyle(LowlightPalette.accent).lineLimit(1)
            if items.isEmpty { Text("No matches.").foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()).dropFirst(start).prefix(6), id: \.element.id) { index, item in
                HStack(spacing: 1) {
                    Text(index == browserIndex ? ">" : " ")
                    Text(item.title).frame(width: max(15, min(46, width / 2)), alignment: .leading).lineLimit(1)
                    Text(item.detail).lineLimit(1)
                }.foregroundStyle(index == browserIndex ? LowlightPalette.accent : LowlightPalette.muted).lineLimit(1)
            }
            if let browserStatus { Text(browserStatus).foregroundStyle(LowlightPalette.muted).lineLimit(1) }
            Text("\(items.isEmpty ? 0 : browserIndex + 1)/\(items.count) · ↑↓ select · enter choose · esc cancel")
                .foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal, 2)
    }

    private func openBrowser(_ kind: BrowserKind, items: [BrowserItem], query: String = "", status: String? = nil) {
        draftBeforeBrowser = draft
        browser = kind
        browserItems = items
        browserIndex = 0
        draft = query
        browserStatus = status
        promptIsFocused = true
    }

    private func closeBrowser() {
        browser = nil
        browserItems = []
        draft = draftBeforeBrowser
        draftBeforeBrowser = ""
        browserStatus = nil
        promptIsFocused = true
    }

    private func chooseBrowserItem() {
        let items = filteredBrowserItems
        guard items.indices.contains(browserIndex), let kind = browser else { return }
        let item = items[browserIndex]
        closeBrowser()
        switch kind {
        case .sessions: resumeConversation(item.id)
        case .models: modelPath = item.id; loadModel()
        case .profiles: useProfile(item.id)
        case .edits: reviseTurn(item.id, retry: false)
        case .search:
            followsTranscript = false
            scrollTarget = UUID(uuidString: item.id)
        }
    }

    private func refreshSessionBrowser() {
        do {
            browserItems = try store.list(query: browserQuery, includeArchived: includeArchived).map {
                BrowserItem(id: $0.id.uuidString,
                            title: "\($0.archived ? "[archived] " : "")\($0.title)\($0.hasDraft ? " · draft" : "")",
                            detail: "\($0.id.uuidString.prefix(8).lowercased()) · \($0.workspacePath)")
            }
            browserStatus = try store.warnings().first.map { "Skipped \($0.filename): \($0.message)" }
        } catch { browserItems = []; browserStatus = error.localizedDescription }
    }

    private func manageSessions(_ argument: String?) {
        let parts = (argument ?? "").split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let action = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""
        if ["archive", "restore", "delete"].contains(action) {
            do {
                let tokens = rest.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let selector = tokens.first else {
                    throw ConversationFeatureError.message("Usage: /sessions \(action) ID")
                }
                let saved = try store.load(selector == "current" ? conversationID.uuidString : selector)
                if action == "delete" {
                    guard tokens.count == 2, tokens[1] == "confirm" else {
                        addCommandNotice("Delete \(saved.title)? Type /sessions delete \(saved.id.uuidString.prefix(8).lowercased()) confirm. A recovery copy is kept in the session .trash folder.")
                        return
                    }
                    try store.delete(saved.id.uuidString)
                    if saved.id == conversationID {
                        var fresh = conversationSnapshot()
                        fresh.id = UUID(); fresh.createdAt = Date(); fresh.updatedAt = fresh.createdAt
                        fresh.title = "New conversation"; fresh.transcript = .init(); fresh.context = .init()
                        fresh.draft = nil; fresh.pendingAttachments = nil; fresh.parentID = nil; fresh.archived = nil
                        fresh.inputHistory = []
                        activateConversation(fresh)
                    }
                    addCommandNotice("Deleted \(saved.title) from the session list.")
                } else {
                    guard tokens.count == 1 else { throw ConversationFeatureError.message("Usage: /sessions \(action) ID") }
                    try store.setArchived(saved.id.uuidString, archived: action == "archive")
                    if saved.id == conversationID { conversationArchived = action == "archive" }
                    addCommandNotice("\(action == "archive" ? "Archived" : "Restored") \(saved.title).")
                }
            } catch { addCommandNotice(error.localizedDescription) }
            return
        }
        guard persistConversation() else { return }
        includeArchived = action == "archived"
        openBrowser(.sessions, items: [], query: includeArchived ? rest : (argument ?? ""))
        refreshSessionBrowser()
    }

    private func manageAttachments(_ argument: String?) {
        let value = argument ?? "list"
        if value == "clear" {
            pendingAttachments = []
            addCommandNotice("Cleared attachments for the next message.")
        } else if value == "list" {
            let rows = pendingAttachments.enumerated().map {
                "\($0.offset + 1). \($0.element.path) · ≈\($0.element.estimatedTokens) tokens"
            }
            addCommandNotice(rows.isEmpty ? "No attachments. Use /attach PATH to preview a UTF-8 file." : rows.joined(separator: "\n") + "\n/attach remove N · /attach clear")
        } else if value.hasPrefix("remove ") {
            guard let number = Int(value.dropFirst(7)), (1...max(1, pendingAttachments.count)).contains(number),
                  !pendingAttachments.isEmpty else {
                addCommandNotice("Use the file number from /attach list."); return
            }
            pendingAttachments.remove(at: number - 1)
        } else {
            do {
                let file = try ChatAttachment.read(value, workspace: URL(fileURLWithPath: workspacePath, isDirectory: true))
                let updated = pendingAttachments.filter { $0.path != file.path } + [file]
                try ChatAttachment.validate(updated)
                pendingAttachments = updated
                let lines = file.text.components(separatedBy: .newlines)
                let preview = lines.prefix(6).map { String($0.prefix(160)) }.joined(separator: "\n")
                addCommandNotice("Attached \(file.path) · \(file.text.utf8.count) bytes · ≈\(file.estimatedTokens) tokens\n\(preview)\n\(lines.count > 6 ? "…\n" : "")Included with your next chat message. /attach clear to remove.")
            } catch { addCommandNotice(error.localizedDescription) }
        }
    }

    private func reviseTurn(_ argument: String?, retry: Bool) {
        if !retry && argument == nil {
            openBrowser(.edits, items: transcript.turns.map {
                BrowserItem(id: String($0.number), title: "\($0.number). \($0.user.text.replacingOccurrences(of: "\n", with: " "))",
                            detail: $0.response?.state.rawValue ?? "unanswered")
            })
            return
        }
        let number = argument.flatMap(Int.init) ?? (argument == nil ? transcript.turns.last?.number : nil)
        guard let number else { addCommandNotice("No turn selected. Use /edit to browse previous messages."); return }
        do {
            guard persistConversation(force: true) else { return }
            let branch = try conversationSnapshot().branched(at: number, before: true)
            try store.save(branch)
            retryAfterConnect = retry
            activateConversation(branch)
            if !retry { addCommandNotice("Edit the restored message and press Enter. The original session is unchanged.") }
        } catch { addCommandNotice(error.localizedDescription) }
    }

    private func branchConversation(_ argument: String?) {
        guard argument == nil || Int(argument!) != nil else { addCommandNotice("Usage: /branch [TURN]"); return }
        do {
            guard persistConversation(force: true) else { return }
            let branch = try conversationSnapshot().branched(at: argument.flatMap(Int.init))
            try store.save(branch)
            activateConversation(branch)
        } catch { addCommandNotice(error.localizedDescription) }
    }

    private func searchTranscript(_ argument: String?) {
        guard let argument, !argument.isEmpty else { addCommandNotice("Usage: /search TEXT"); return }
        scrollTarget = nil
        openBrowser(.search, items: transcript.search(argument).map {
            BrowserItem(id: $0.user.id.uuidString, title: "\($0.number). \($0.user.text.replacingOccurrences(of: "\n", with: " "))",
                        detail: String(($0.response?.text ?? "").replacingOccurrences(of: "\n", with: " ").prefix(150)))
        }, status: "Matches for: \(argument)")
    }

    private func exportConversation(_ argument: String?) {
        guard var path = argument, !path.isEmpty else { addCommandNotice("Usage: /export PATH"); return }
        if path.first == "\"", path.last == "\"" { path = String(path.dropFirst().dropLast()) }
        do {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath,
                          relativeTo: URL(fileURLWithPath: workspacePath, isDirectory: true)).standardizedFileURL
            try conversationSnapshot().exportMarkdown(to: url)
            addCommandNotice("Exported \(url.path).")
        } catch { addCommandNotice("Export failed: \(error.localizedDescription)") }
    }

    private func openModelBrowser() {
        openBrowser(.models, items: modelCatalog.map {
            BrowserItem(id: $0.id, title: $0.id, detail: $0.contextWindow.map { "\($0) context tokens" } ?? "context not advertised")
        }, status: modelCatalog.isEmpty ? "Use /connection reconnect to refresh, or /model NAME if listing is unavailable." : nil)
    }

    private var selectedModelInfo: OpenAIModel? { modelCatalog.first { $0.id == modelName } }
    private var capabilityIssues: [String] {
        selectedModelInfo?.settingIssues(contextWindow: contextWindowTokens, effort: reasoningEffort) ?? []
    }

    private var connectionDescription: String {
        let keySet = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let reportedWindow = selectedModelInfo?.contextWindow.map(String.init) ?? "not advertised (unverified)"
        let efforts = selectedModelInfo?.supportedReasoningEfforts.map { $0.isEmpty ? "none" : $0.joined(separator: ", ") }
            ?? "not advertised (unverified)"
        return "Endpoint: \(endpoint)\nModel: \(modelName)\nAuthentication: \(apiKeyEnvironment) is \(keySet ? "set" : "not set")"
            + "\nConfigured context: \(contextWindowTokens); output reserve: \(maximumTokens); safety: \(contextSafetyReserveTokens)"
            + "\nServer-reported context: \(reportedWindow)\nServer-reported efforts: \(efforts)"
            + "\nSelected effort: \(reasoningEffort?.rawValue ?? "default")\n\(availableModelsSummary)"
            + (capabilityIssues.isEmpty ? "" : "\n" + capabilityIssues.joined(separator: "\n"))
            + "\nUse /connection reconnect to refresh."
    }

    private func manageProfiles(_ argument: String?) {
        let parts = (argument ?? "").split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        do {
            if parts.isEmpty {
                let catalog = try ConnectionProfileStore().list()
                openBrowser(.profiles, items: catalog.profiles.map {
                    BrowserItem(id: $0.name, title: $0.name, detail: "\($0.model) · \($0.endpoint)")
                }, status: catalog.warnings.first ?? (catalog.profiles.isEmpty ? "Use /profile save NAME to save these settings." : nil))
            } else if parts.count == 2, parts[0] == "save" {
                let profile = ConnectionProfile(name: parts[1], endpoint: endpoint, model: modelName,
                    apiKeyEnvironment: apiKeyEnvironment, contextWindow: contextWindowTokens,
                    maximumTokens: maximumTokens, safetyReserve: contextSafetyReserveTokens,
                    compactAtPercent: contextCompactAtPercent, reasoningEffort: reasoningEffort)
                try ConnectionProfileStore().save(profile)
                addCommandNotice("Saved profile \(profile.name). Launch with lowlight --profile \(profile.name). Authentication remains in \(apiKeyEnvironment).")
            } else if parts.count == 2, parts[0] == "use" { useProfile(parts[1]) }
            else { addCommandNotice("Usage: /profile [save NAME|use NAME]") }
        } catch { addCommandNotice(error.localizedDescription) }
    }

    private func useProfile(_ name: String) {
        do {
            let profile = try ConnectionProfileStore().load(name)
            endpoint = profile.endpoint; modelPath = profile.model
            apiKeyEnvironment = profile.apiKeyEnvironment; contextWindowTokens = profile.contextWindow
            maximumTokens = profile.maximumTokens; contextSafetyReserveTokens = profile.safetyReserve
            contextCompactAtPercent = profile.compactAtPercent; reasoningEffort = profile.reasoningEffort
            _ = persistConversation()
            loadModel()
        } catch { addCommandNotice(error.localizedDescription) }
    }

    private func compactTokenCount(_ count: Int) -> String {
        guard count >= 1_000 else { return String(count) }
        let tenths = (count + 50) / 100
        return "\(tenths / 10).\(tenths % 10)k"
    }
}

@MainActor
private struct LoadingProgressView: View {
    let label: String

    private let width = 24
    private let bandWidth = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: .milliseconds(120))) { context in
            let step = Int(context.instant.offset.totalSeconds / 0.12)
            let travel = width - bandWidth
            let cycle = max(1, travel * 2)
            let phase = step % cycle
            let offset = phase <= travel ? phase : cycle - phase

            VStack(alignment: .leading, spacing: 0) {
                Text(label).foregroundStyle(LowlightPalette.accent)
                HStack(spacing: 0) {
                    Text(String(repeating: "─", count: offset))
                        .foregroundStyle(.secondary)
                    Text(String(repeating: "█", count: bandWidth))
                        .foregroundStyle(LowlightPalette.accent)
                    Text(String(repeating: "─", count: travel - offset))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
private struct TranscriptRow: View {
    let message: ChatMessage
    let elapsedSeconds: Int
    let showThinking: Bool

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let attachments = message.attachments, !attachments.isEmpty {
                Text("Attached: " + attachments.map(\.name).joined(separator: ", "))
                    .foregroundStyle(LowlightPalette.muted).padding(.leading, 2)
            }
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                Text("\(showThinking ? "▾" : "▸") Thinking · ctrl-t to \(showThinking ? "hide" : "show")")
                    .foregroundStyle(LowlightPalette.detailAccent)
                if showThinking {
                    Text(reasoning).foregroundStyle(LowlightPalette.muted).padding(.leading, 2)
                }
                if !message.text.isEmpty {
                    Text("Answer").bold().foregroundStyle(LowlightPalette.accent)
                }
            }
        HStack(alignment: .top, spacing: 1) {
            if message.role == .notice {
                Text("◇").foregroundStyle(LowlightPalette.accent)
                Text(message.text).foregroundStyle(.secondary)
            } else if message.role == .assistant,
               message.state == .streaming,
               message.text.isEmpty
            {
                Spinner().foregroundStyle(LowlightPalette.accent)
                Text("\(message.reasoning == nil ? "Working" : "Thinking") (\(elapsedSeconds)s • esc to interrupt)")
                    .foregroundStyle(.secondary)
            } else {
                Text(message.role == .user ? "›" : "•")
                    .foregroundStyle(
                        message.role == .user
                            ? LowlightPalette.detailAccent
                            : LowlightPalette.accent
                    )
                if message.state == .failed {
                    Text(message.text).foregroundStyle(LowlightPalette.danger)
                } else {
                    if message.role == .assistant {
                        markdownText(message.text)
                    } else {
                        Text(message.text).foregroundStyle(LowlightPalette.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func markdownText(_ source: String) -> Text {
        var interpolation = Text.StringInterpolation(literalCapacity: source.count, interpolationCount: 8)
        for span in ChatMarkdown.spans(source) {
            var text = Text(span.text)
            if span.bold { text = text.bold() }
            if span.italic { text = text.italic() }
            if span.code { text = text.foregroundStyle(LowlightPalette.accent) }
            interpolation.appendInterpolation(text)
        }
        return Text(Text.RichContent(stringInterpolation: interpolation))
    }
}

private enum ChatInputError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { "Invalid input." } }
}

private func readInstructionFile(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        throw ChatInputError.message("System prompt file must be a regular UTF-8 file.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 128 * 1_024 + 1) ?? Data()
    guard data.count <= 128 * 1_024, let text = String(data: data, encoding: .utf8) else {
        throw ChatInputError.message("System prompt file must be UTF-8 and at most 128 KiB.")
    }
    return text
}

private func validateChatEndpoint(_ endpoint: String) throws {
    guard let url = URLComponents(string: endpoint),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
        throw ChatInputError.message("Use an HTTP(S) endpoint without embedded credentials, query, or fragment. Supply authentication through --api-key-env.")
    }
}
