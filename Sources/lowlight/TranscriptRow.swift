import Foundation
import ModelChatCore
import SwiftTUI

/// Inline role markers and a rule before each prompt separate conversation turns.
struct TranscriptRow: View {
    @Environment(\.terminalAppearance) private var terminalAppearance
    private var palette: LowlightPalette { LowlightPalette(appearance: terminalAppearance) }

    let message: ChatMessage
    let elapsedSeconds: Int
    let showThinking: Bool

    private var usesASCII: Bool {
        let value = ProcessInfo.processInfo.environment["SWIFTTUI_ASCII"] ?? "0"
        return CommandLine.arguments.contains("--ascii") || (!value.isEmpty && value != "0")
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userMessage
            case .assistant:
                assistantMessage
            case .notice:
                HStack(alignment: .top, spacing: 1) {
                    Text(usesASCII ? "-" : "·")
                    Text(message.text)
                }
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 2)
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 1) {
            Text(usesASCII ? ">" : "›").foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(message.text).foregroundStyle(palette.ink)
                attachments
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .border(palette.border, set: usesASCII ? .ascii : .single, sides: .top)
    }

    private var assistantMessage: some View {
        HStack(alignment: .top, spacing: 1) {
            Text(usesASCII ? "*" : "•").foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                attachments
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    Text("\(showThinking ? "▾" : "▸") Thinking · ctrl-t to \(showThinking ? "hide" : "show")")
                        .foregroundStyle(palette.muted)
                    if showThinking {
                        Text(reasoning).foregroundStyle(palette.muted).padding(.leading, 2)
                    }
                    if !message.text.isEmpty { Text(" ") }
                }
                if message.state == .streaming, message.text.isEmpty {
                    HStack(spacing: 1) {
                        Spinner().foregroundStyle(palette.accent)
                        Text("\(message.reasoning == nil ? "Working" : "Thinking") (\(elapsedSeconds)s · esc to interrupt)")
                            .foregroundStyle(palette.muted)
                    }
                } else if message.state == .failed {
                    Text(message.text).foregroundStyle(palette.danger)
                } else {
                    markdownText(message.text).foregroundStyle(palette.ink)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var attachments: some View {
        if let attachments = message.attachments, !attachments.isEmpty {
            Text("Attached: " + attachments.map(\.name).joined(separator: ", "))
                .foregroundStyle(palette.muted)
        }
    }

    private func markdownText(_ source: String) -> Text {
        var interpolation = Text.StringInterpolation(literalCapacity: source.count, interpolationCount: 8)
        for span in ChatMarkdown.spans(source) {
            var text = Text(span.text)
            if span.bold { text = text.bold() }
            if span.italic { text = text.italic() }
            if span.code { text = text.foregroundStyle(palette.accent) }
            interpolation.appendInterpolation(text)
        }
        return Text(Text.RichContent(stringInterpolation: interpolation))
    }
}
