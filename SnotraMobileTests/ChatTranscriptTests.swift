import Foundation
import Testing
@testable import SnotraMobile

/// The stream assembly: a running turn from its events (remote-interface.md §8.2).
struct ChatTranscriptTests {
    func opened(_ messages: [JSONValue], state: String = "idle", before: JSONValue = .null) throws -> ChatTranscript {
        var result: [String: JSONValue] = ["chatId": "c1", "title": "Release notes", "state": .string(state), "messages": .array(messages)]
        if before != .null { result["before"] = before }
        return try ChatTranscript(opened: .object(result))
    }

    let question = JSONValue.object(["messageId": "m0", "role": "user", "text": "Write the notes"])
    let answer = JSONValue.object(["messageId": "m1", "role": "assistant", "text": "Here they are."])

    @Test func aDisplayMessageDecodesWithItsPlaceholdersAndMarks() throws {
        let message = try JSONValue.object([
            "messageId": "m3", "role": "assistant", "text": "Done",
            "toolLines": .array([.object(["line": "Read README.md", "tool": "read_file", "status": "done"])]),
            "attachments": .array([.object(["kind": "image", "placeholder": true, "name": "chart.png"]), .object(["kind": "image", "placeholder": true])]),
            "interrupted": true,
            "origin": .object(["kind": "relay", "client": "Snotra for iPhone"]),
            "unknownField": 1,
        ]).decoded(as: ChatMessage.self)
        #expect(message.toolLines == [.init(line: "Read README.md", tool: "read_file", status: "done")])
        #expect(message.images == ["chart.png", nil])
        #expect(message.interrupted)
        #expect(message.origin == .init(kind: "relay", client: "Snotra for iPhone"))
    }

    @Test func deltasMakeTheTextInOrder() throws {
        var chat = try opened([question])
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "Here "]))
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "they "]))
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "are."]))
        #expect(chat.live?.text == "Here they are.")
        #expect(chat.state == .running)
        #expect(chat.isRunning)
        #expect(chat.messages.count == 1)
    }

    @Test func aToolLineIsUpdatedByItsCall() throws {
        var chat = try opened([question])
        chat.apply("chat.tool-line", .object(["chatId": "c1", "runId": "r1", "callIndex": 0, "phase": "pending", "tool": "read_file", "line": "Reading README.md"]))
        chat.apply("chat.tool-line", .object(["chatId": "c1", "runId": "r1", "callIndex": 1, "phase": "start", "tool": "shell", "line": "Running git log"]))
        chat.apply("chat.tool-line", .object(["chatId": "c1", "runId": "r1", "callIndex": 0, "phase": "done", "tool": "read_file", "line": "Read README.md"]))
        let lines = try #require(chat.live?.toolLines.map(\.line))
        #expect(lines.map(\.line) == ["Read README.md", "Running git log"])
        #expect(lines.map(\.status) == ["done", "start"])
    }

    @Test func runEndKeepsTheAssembledAnswerUntilTheStoredOneIsThere() throws {
        var chat = try opened([question])
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "Here they are."]))
        let readAgain = chat.apply("chat.progress", .object(["chatId": "c1", "runId": "r1", "type": "run-end"]))
        #expect(readAgain)
        #expect(!chat.isRunning)
        #expect(chat.hasProvisionalAnswer)
        #expect(chat.messages.last?.text == "Here they are.")

        // The desktop has not stored it yet: nothing is lost.
        chat.reloaded(try opened([question]))
        #expect(chat.hasProvisionalAnswer)
        #expect(chat.messages.count == 2)

        chat.reloaded(try opened([question, answer]))
        #expect(!chat.hasProvisionalAnswer)
        #expect(chat.messages.map(\.messageId) == ["m0", "m1"])
        #expect(chat.live == nil)
    }

    @Test func otherProgressMarksTheChatRunningWithoutText() throws {
        var chat = try opened([question])
        let readAgain = chat.apply("chat.progress", .object(["chatId": "c1", "runId": "r1", "type": "phase", "phase": "thinking"]))
        #expect(!readAgain)
        #expect(chat.isRunning)
        #expect(chat.live?.runId == "r1")
    }

    @Test func eventsOfANewRunStartANewTurn() throws {
        var chat = try opened([question])
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "First"]))
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r2", "text": "Second"]))
        #expect(chat.live?.runId == "r2")
        #expect(chat.live?.text == "Second")
        #expect(chat.messages.last?.text == "First")
    }

    @Test func aReloadWhileRunningKeepsTheLiveTurn() throws {
        var chat = try opened([question], state: "running")
        chat.apply("chat.delta", .object(["chatId": "c1", "runId": "r1", "text": "So far"]))
        chat.reloaded(try opened([question], state: "running"))
        #expect(chat.live?.text == "So far")
        #expect(chat.isRunning)
    }

    @Test func theOwnQuestionShowsAtOnceAndAnotherFrontEndsArrivesOnce() throws {
        var chat = try opened([question, answer])
        chat.asked("And in German?", messageId: "m2")
        chat.asked("And in German?", messageId: "m2")
        #expect(chat.messages.map(\.messageId) == ["m0", "m1", "m2"])
        #expect(chat.messages.last?.origin?.kind == "relay")
        #expect(chat.state == .running)

        let other = JSONValue.object(["messageId": "m4", "role": "user", "text": "From the desktop"])
        chat.apply("chat.message", .object(["chatId": "c1", "message": other]))
        chat.apply("chat.message", .object(["chatId": "c1", "message": other]))
        #expect(chat.messages.map(\.messageId) == ["m0", "m1", "m2", "m4"])
    }

    @Test func olderMessagesGoBeforeTheShownOnes() throws {
        var chat = try opened([answer], before: "m1")
        #expect(chat.before == "m1")
        chat.prepend([try question.decoded(as: ChatMessage.self)], before: nil)
        #expect(chat.messages.map(\.messageId) == ["m0", "m1"])
        #expect(chat.before == nil)
    }

    @Test func aNewTitleArrives() throws {
        var chat = try opened([])
        chat.apply("chat.updated", .object(["chatId": "c1", "title": "Release notes for 1.4"]))
        #expect(chat.title == "Release notes for 1.4")
    }
}

struct MarkdownBlocksTests {
    @Test func proseHeadingsAndCodeAreCutApart() {
        let text = """
        # Plan
        First **step**.
        Still the first paragraph.

        ```swift
        let x = 1

        print(x)
        ```
        Done.
        """
        #expect(MarkdownBlock.blocks(text) == [
            .heading("Plan"),
            .prose("First **step**.\nStill the first paragraph."),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .prose("Done."),
        ])
    }

    @Test func aCodeBlockStillOpenWhileStreamingRunsToTheEnd() {
        #expect(MarkdownBlock.blocks("Look:\n```\nnpm test") == [.prose("Look:"), .code(language: nil, text: "npm test")])
    }

    @Test func aHashWithoutASpaceIsNoHeading() {
        #expect(MarkdownBlock.blocks("#1194 is merged") == [.prose("#1194 is merged")])
    }
}
