import Foundation

/// An answer's Markdown cut into what a phone lays out differently: code
/// blocks scroll sideways in a monospaced box, headings stand out, the rest is
/// prose with its inline styling. A code block still open while the answer
/// streams runs to the end of the text.
enum MarkdownBlock: Equatable {
    case prose(String)
    case heading(String)
    case code(language: String?, text: String)

    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: (language: String?, lines: [Substring])?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
            prose = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    code = (language.isEmpty ? nil : language, [])
                }
            } else if code != nil {
                code?.lines.append(line)
            } else if let heading = heading(trimmed) {
                flushProse()
                blocks.append(.heading(heading))
            } else if trimmed.isEmpty {
                flushProse()
            } else {
                prose.append(line)
            }
        }
        if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }

    private static func heading(_ line: Substring) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
    }
}

extension AttributedString {
    /// Inline Markdown — emphasis, code, links — with the line breaks kept;
    /// plain text where it does not parse.
    init(inlineMarkdown text: String) {
        self = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}
