import Foundation
#if os(Linux)
import Markdown
#endif

/// Presentation only: the original Markdown remains in the saved transcript.
public enum ChatMarkdown {
    public struct Span: Equatable, Sendable {
        public let text: String
        public let bold: Bool
        public let italic: Bool
        public let code: Bool
    }

    public static func spans(_ source: String) -> [Span] {
        var result: [Span] = []
        var fence: String?
        let lines = source.components(separatedBy: "\n")
        for (index, original) in lines.enumerated() {
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            let delimiter = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if let delimiter, fence == nil || fence == delimiter {
                fence = fence == nil ? delimiter : nil
                continue
            }
            let newline = index < lines.count - 1 ? "\n" : ""
            if fence != nil {
                result.append(Span(text: original + newline, bold: false, italic: false, code: true))
                continue
            }
            let hashes = original.prefix(while: { $0 == "#" }).count
            let heading = (1...6).contains(hashes) && original.dropFirst(hashes).hasPrefix(" ")
            let line = heading ? String(original.dropFirst(hashes + 1)) : original
            #if os(Linux)
            result += inlineSpans(line, heading: heading)
            if !newline.isEmpty { result.append(Span(text: newline, bold: false, italic: false, code: false)) }
            #else
            if let attributed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in attributed.runs {
                    let intent = run.inlinePresentationIntent ?? []
                    result.append(Span(text: String(attributed[run.range].characters),
                                       bold: heading || intent.contains(.stronglyEmphasized),
                                       italic: intent.contains(.emphasized), code: intent.contains(.code)))
                }
                if !newline.isEmpty { result.append(Span(text: newline, bold: false, italic: false, code: false)) }
            } else {
                result.append(Span(text: original + newline, bold: false, italic: false, code: false))
            }
            #endif
        }
        return result
    }

    #if os(Linux)
    private static func inlineSpans(_ line: String, heading: Bool) -> [Span] {
        let document = Document(parsing: line)
        guard document.childCount == 1, let paragraph = document.child(at: 0) as? Paragraph else {
            return [Span(text: line, bold: heading, italic: false, code: false)]
        }
        var result: [Span] = []
        func visit(_ node: any Markup, bold: Bool, italic: Bool) {
            if let text = node as? Markdown.Text {
                result.append(Span(text: text.string, bold: bold, italic: italic, code: false))
            } else if let code = node as? InlineCode {
                result.append(Span(text: code.code, bold: bold, italic: italic, code: true))
            } else if let html = node as? InlineHTML {
                result.append(Span(text: html.rawHTML, bold: bold, italic: italic, code: false))
            } else {
                for child in node.children {
                    visit(child, bold: bold || node is Strong, italic: italic || node is Emphasis)
                }
            }
        }
        visit(paragraph, bold: heading, italic: false)
        return result
    }
    #endif

}
