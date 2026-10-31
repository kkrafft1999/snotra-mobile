import Foundation
import SwiftUI
import Testing
@testable import SnotraMobile

/// Cards about knowledge files (snotra#1276, snotra#1319, snotra-mobile#92):
/// what the phone decodes and shows, how it answers, and the capability it
/// announces so that the desktop lets it allow one at all.
@MainActor
struct KnowledgeCardTests {
    static let rememberCard = JSONValue.object([
        "requestId": "k-1", "chatId": "c1", "tool": "remember", "riskClasses": .array(["write"]),
        "targets": .array([]), "reason": "Snotra reads this file in every chat.", "checkpoint": "access",
        "options": .array(["allow-once", "deny"]), "knowledge": true, "knowledgeWarning": true,
        "knowledgeCard": .object([
            "kind": "rule", "scope": "user", "entry": "When you answer me, answer in German.", "origin": "requested",
            "topic": "language", "description": "When you answer the user", "always": true,
            "target": .object(["path": "~/.snotra/rules/language.md", "exists": false, "file": "rules"]),
            "replaced": .object(["text": "Answer in German.", "where": "memory", "count": 1]),
            "folderInstructions": .object(["agentsMd": true, "rulesFiles": 2]),
            "alwaysOverBudget": true,
        ]),
    ])

    @Test func aRememberCardDecodesEveryField() throws {
        let request = try Self.rememberCard.decoded(as: ApprovalRequest.self)
        #expect(request.knowledge)
        #expect(request.knowledgeWarning)
        let card = try #require(request.knowledgeCard)
        #expect(card.kind == "rule")
        #expect(card.scope == "user")
        #expect(card.target == .init(path: "~/.snotra/rules/language.md", exists: false))
        #expect(card.replaced == .init(text: "Answer in German."))
        #expect(card.isAlways)
        #expect(KnowledgeCardSection.appliesWhen(card) == "When you answer the user")
        let notes = KnowledgeCardSection.notes(card)
        #expect(notes.count == 2)
        #expect(notes.last?.key == "This folder brings its own instructions: AGENTS.md, %lld rules files.")
    }

    @Test func aKnowledgeCardIsAllowedAsProposedAndAKnowledgeChangeIsKeptOrReset() throws {
        let remember = try Self.rememberCard.decoded(as: ApprovalRequest.self)
        #expect(ApprovalCardView.allowLabel(remember).key == "Allow as proposed")
        #expect(ApprovalCardView.heading(remember).key == "Snotra wants to remember a rule")
        let change = try JSONValue.object([
            "requestId": "k-2", "chatId": "c1", "tool": "shell_execute", "checkpoint": "knowledge", "knowledge": true,
            "targets": .array([.object(["path": "AGENTS.md", "kind": "file", "exists": true, "sensitive": false, "knowledge": "agents"])]),
            "knowledgeChange": .object(["files": .array([.object(["path": "AGENTS.md", "status": "changed"])])]),
            "preview": .object(["kind": "diff", "text": "-a\n+b", "truncated": false, "masked": false]),
            "options": .array(["allow-once", "deny"]),
        ]).decoded(as: ApprovalRequest.self)
        #expect(change.knowledgeChange?.files == [.init(path: "AGENTS.md", status: "changed")])
        #expect(change.targets.first?.knowledge == "agents")
        #expect(ApprovalCardView.allowLabel(change).key == "Keep")
        #expect(ApprovalCardView.heading(change).key == "A command changed a knowledge file")
    }

    @Test func aPlainCardStaysAsItWas() throws {
        let request = try ApprovalTranscriptTests.card.decoded(as: ApprovalRequest.self)
        #expect(!request.knowledge)
        #expect(request.knowledgeCard == nil)
        #expect(ApprovalCardView.allowLabel(request).key == "Allow once")
    }

}

/// The knowledge cards as pictures, light and dark, default and largest text,
/// English and German (snotra-mobile#92). Off unless `SNOTRA_SNAPSHOT_DIR`
/// names a folder, as for `MirrorSnapshots`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"] != nil))
@MainActor
struct KnowledgeCardSnapshots {
    @Test func writesTheKnowledgeCards() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let remember = try KnowledgeCardTests.rememberCard.decoded(as: ApprovalRequest.self)
        let change = ApprovalRequest(
            requestId: "k-2", chatId: "c1", tool: "shell_execute",
            targets: [.init(path: "AGENTS.md", knowledge: "agents")],
            reason: "Snotra reads this file in every chat in this folder.", checkpoint: "knowledge",
            preview: .init(text: "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@\n - Tests run with npm test.\n+- Lint with npm run lint."),
            knowledge: true, knowledgeChange: .init(files: [.init(path: "AGENTS.md", status: "changed")]))
        let oldApp = ApprovalRequest(
            requestId: "k-3", chatId: "c1", tool: "edit_file",
            targets: [.init(path: ".agents/rules/deploy.md", knowledge: "rules", knowledgeAlways: true)],
            reason: "Snotra reads this file in every chat in this folder.", options: ["deny"], knowledge: true)
        let card = { (request: ApprovalRequest) in
            AnyView(ScrollView { ApprovalCardView(card: ApprovalCard(request: request), answering: false, respond: { _ in }).padding() })
        }
        try await writeHostedSnapshots([
            ("remember", card(remember)),
            ("change", card(change)),
            ("deny-only", card(oldApp)),
        ], prefix: "knowledge", to: folder)
    }
}
