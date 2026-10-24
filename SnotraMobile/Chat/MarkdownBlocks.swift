import Foundation

/// An answer's Markdown cut into what a phone lays out differently: code
/// blocks scroll sideways in a monospaced box, tables likewise in a grid,
/// headings stand out, lists and quotes get their marks, the rest is prose
/// with its inline styling. A code block still open while the answer streams
/// runs to the end of the text.
enum MarkdownBlock: Equatable {
    case prose(String)
    case heading(String)
    case code(language: String?, text: String)
    case table(Table)
    case list([ListItem])
    case quote(String)
    case rule

    struct Table: Equatable {
        enum Alignment: Equatable { case leading, center, trailing }

        var header: [String]
        var alignments: [Alignment]
        /// As wide as the header: short rows filled up, long ones cut.
        var rows: [[String]]
    }

    struct ListItem: Equatable {
        /// "•" or the item's number with its dot, as written.
        var marker: String
        var text: String
        /// Nesting by indentation, from 0.
        var level: Int = 0
    }

    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: (language: String?, lines: [Substring])?
        var items: [ListItem] = []
        var quote: [Substring] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
            prose = []
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)) }
            items = []
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.quote(text)) }
            quote = []
        }
        func flush() {
            flushProse()
            flushList()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.drop { $0 == " " }
            index += 1
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    code = (language.isEmpty ? nil : language, [])
                }
            } else if code != nil {
                code?.lines.append(line)
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(.heading(heading))
            } else if trimmed.isEmpty {
                flush()
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushProse()
                flushList()
                quote.append(trimmed.dropFirst().drop { $0 == " " })
            } else if index < lines.count, trimmed.contains("|"),
                      let alignments = alignments(lines[index]) {
                let header = cells(trimmed)
                guard header.count == alignments.count else {
                    prose.append(line)
                    continue
                }
                flush()
                index += 1
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|") {
                    let row = cells(lines[index].drop { $0 == " " })
                    rows.append(Array((row + Array(repeating: "", count: header.count)).prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(Table(header: header, alignments: alignments, rows: rows)))
            } else if let item = listItem(line) {
                flushProse()
                flushQuote()
                items.append(item)
            } else if !items.isEmpty, line.first == " " {
                // An indented line goes on with the item above it.
                items[items.count - 1].text += "\n" + trimmed
            } else if !quote.isEmpty {
                quote.append(trimmed)
            } else {
                flushList()
                prose.append(line)
            }
        }
        if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: Substring) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
    }

    /// `---`, `***` or `___`, three or more, spaces allowed between.
    private static func isRule(_ line: Substring) -> Bool {
        let marks = line.filter { $0 != " " }
        guard let mark = marks.first, "-*_".contains(mark), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    /// `- item`, `* item`, `+ item` or `1. item`; two spaces of indentation make a level.
    private static func listItem(_ line: Substring) -> ListItem? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let mark = rest.first, "-*+".contains(mark), rest.dropFirst().first == " " {
            return ListItem(marker: "•", text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces), level: indent / 2)
        }
        let digits = rest.prefix { $0.isNumber }
        let after = rest.dropFirst(digits.count)
        guard (1...9).contains(digits.count), let dot = after.first, dot == "." || dot == ")",
              after.dropFirst().first == " "
        else { return nil }
        return ListItem(marker: String(digits) + ".",text: after.dropFirst(2).trimmingCharacters(in: .whitespaces), level: indent / 2)
    }

    /// The line under a table's header, `| --- | :---: | ---: |`, read as its columns' alignment.
    private static func alignments(_ line: Substring) -> [Table.Alignment]? {
        guard line.contains("-") else { return nil }
        let columns = cells(line.drop { $0 == " " })
        guard !columns.isEmpty else { return nil }
        var alignments: [Table.Alignment] = []
        for column in columns {
            let leading = column.hasPrefix(":"), trailing = column.hasSuffix(":")
            let dashes = column.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return alignments
    }

    /// A table row's cells, without the outer pipes; `\|` stays a pipe inside a cell.
    private static func cells(_ line: Substring) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)[...]
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }
        var cells: [String] = [], cell = "", escaped = false
        for character in row {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
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
