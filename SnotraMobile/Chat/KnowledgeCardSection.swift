import SwiftUI

/// The part of an approval card that is about knowledge — a file Snotra reads
/// in every chat (snotra#1276, snotra#1319, snotra-mobile#92). The phone shows
/// all of it: what Snotra wants to remember and for whom, where it goes, an
/// `always` rule, the entry it replaces, what a command changed, and the
/// warning when the chat met a likely injection. It is answered only as
/// proposed; re-sorting stays on the desktop.
struct KnowledgeCardSection: View {
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if request.knowledgeWarning {
                Label("Earlier in this chat, a tool result or this folder's own text read like hidden instructions. Check that you want this in a file Snotra reads in every chat.",
                      systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval.knowledge.warning")
            }
            if let card = request.knowledgeCard {
                remember(card)
            }
            if let change = request.knowledgeChange {
                ForEach(Array(change.files.enumerated()), id: \.offset) { _, file in
                    Label {
                        Text(file.path).lineLimit(2).truncationMode(.middle)
                    } icon: {
                        Image(systemName: file.status == "added" ? "doc.badge.plus" : file.status == "removed" ? "doc.badge.minus" : "doc.badge.ellipsis")
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .accessibilityLabel(Text(Self.changeLabel(file)))
                }
            }
        }
    }

    @ViewBuilder
    private func remember(_ card: ApprovalRequest.KnowledgeCard) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Kind").foregroundStyle(.secondary)
                Text(Self.kind(card.kind)).fontWeight(.semibold)
            }
            GridRow {
                Text("Who reads it").foregroundStyle(.secondary)
                Text(Self.reader(card.scope)).fontWeight(.semibold)
            }
            if let target = card.target {
                GridRow {
                    Text("Target").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.path).font(.system(.footnote, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        Text(target.exists ? Self.readerNote(card.scope) : Self.newNote(card.scope))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if card.kind == "rule", let applies = Self.appliesWhen(card) {
                GridRow {
                    Text("Applies when").foregroundStyle(.secondary)
                    Text(applies).fixedSize(horizontal: false, vertical: true)
                }
            }
            if card.isAlways {
                GridRow {
                    Text("Always").foregroundStyle(.secondary)
                    Text(card.scope == "user" ? "applies in every folder, in every conversation" : "goes along with every message in this folder")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.footnote)
        VStack(alignment: .leading, spacing: 4) {
            Text(card.entry)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let replaced = card.replaced {
                Text("Replaces: \(replaced.text)")
                    .font(.system(.caption, design: .monospaced))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        ForEach(Array(Self.notes(card).enumerated()), id: \.offset) { _, note in
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func kind(_ kind: String) -> LocalizedStringResource {
        switch kind {
        case "rule": "Rule"
        case "instruction": "Procedure"
        default: "Fact"
        }
    }

    static func reader(_ scope: String) -> LocalizedStringResource {
        switch scope {
        case "team": "Every tool here"
        case "workspace": "Snotra in this folder"
        default: "Only you"
        }
    }

    static func readerNote(_ scope: String) -> LocalizedStringResource {
        switch scope {
        case "team": "AGENTS.md is read by every tool in this folder and usually shared with the team"
        case "workspace": "read by Snotra in this folder; versioned with the folder if it is a repository"
        default: "applies in every folder"
        }
    }

    static func newNote(_ scope: String) -> LocalizedStringResource {
        switch scope {
        case "team": "new · AGENTS.md is read by every tool in this folder and usually shared with the team"
        case "workspace": "new · read by Snotra in this folder; versioned with the folder if it is a repository"
        default: "new · applies in every folder"
        }
    }

    static func appliesWhen(_ card: ApprovalRequest.KnowledgeCard) -> String? {
        let old = card.ruleFile?.description ?? ""
        let next = card.description ?? ""
        if !old.isEmpty && !next.isEmpty && old != next { return "\(old) → \(next)" }
        let shown = next.isEmpty ? old : next
        return shown.isEmpty ? nil : shown
    }

    /// Resources, not strings: a note follows the language of the view it is in.
    static func notes(_ card: ApprovalRequest.KnowledgeCard) -> [LocalizedStringResource] {
        var notes: [LocalizedStringResource] = []
        if card.switchedOff {
            notes.append("This is switched off in the settings: it is written, but applies only once it is switched on.")
        }
        if card.isAlways && card.alwaysOverBudget {
            notes.append("The always-rules of this level are full: this one is fetched when it applies instead.")
        }
        if card.scope == "user", let folder = card.folderInstructions {
            switch (folder.agentsMd, folder.rulesFiles) {
            case (true, 0): notes.append("This folder brings its own instructions: AGENTS.md.")
            case (true, let count): notes.append("This folder brings its own instructions: AGENTS.md, \(count) rules files.")
            case (false, let count) where count > 0: notes.append("This folder brings its own instructions: \(count) rules files.")
            default: break
            }
        }
        return notes
    }

    static func changeLabel(_ file: ApprovalRequest.KnowledgeChange.File) -> LocalizedStringResource {
        switch file.status {
        case "added": "Added: \(file.path)"
        case "removed": "Removed: \(file.path)"
        default: "Changed: \(file.path)"
        }
    }
}

#Preview("Remember a rule") {
    KnowledgeCardSection(request: ApprovalRequest(
        requestId: "k-1", chatId: "c1", tool: "remember", knowledge: true, knowledgeWarning: true,
        knowledgeCard: .init(kind: "rule", scope: "user", entry: "When you answer me, answer in German.", topic: "language",
                             description: "When you answer the user", always: true,
                             target: .init(path: "~/.snotra/rules/language.md", exists: false),
                             folderInstructions: .init(agentsMd: true, rulesFiles: 2))))
        .padding()
}
