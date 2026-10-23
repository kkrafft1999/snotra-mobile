import Foundation
import Testing
@testable import SnotraMobile

/// The app against Snotra's own desktop half of the channel — its
/// `remote-channel.js` and `remote-dispatcher.js`, behind the relay stand-in —
/// from pairing through a followed, a stopped and a new chat and its approval
/// cards to the workspace switch. Off unless
/// `SNOTRA_DESKTOP_HARNESS` (`TEST_RUNNER_SNOTRA_DESKTOP_HARNESS` for
/// `xcodebuild test`) names the file `scripts/desktop-harness.js` wrote: the
/// relay's configuration and the key to type. CI does not run it.
///
/// The harness's desktop knows three folders and opens two of them to the
/// phone, *snotra* (open at the desktop) and *website*; opening *website*
/// starts a turn there, so that switching back is refused.
@Suite(.enabled(if: DesktopHarness.fixture != nil))
@MainActor
struct DesktopLiveTests {
    @Test func pairsFollowsWritesAndSwitches() async throws {
        let fixture = try #require(DesktopHarness.fixture)
        let endpoint = fixture.endpoint
        let transport = URLSessionTransport()
        let keys = MemoryStore(), pairings = MemoryStore()
        let flow = PairingFlow(
            relays: [endpoint], transport: transport,
            keyStore: DeviceKeyStore(store: keys, kind: .software),
            pairingStore: PairingStore(store: pairings), wordList: try .bundled())
        flow.submit(typed: fixture.typedKey)
        for _ in 0..<200 where !isPaired(flow.step) { try await Task.sleep(for: .milliseconds(100)) }
        try #require(isPaired(flow.step), "not paired: \(flow.step)")

        let model = RemoteModel(relays: [endpoint], transport: transport,
                                keyStore: DeviceKeyStore(store: keys, kind: .software),
                                pairingStore: PairingStore(store: pairings))
        model.reload()
        model.activate()
        let mirror = try #require(model.mirror)
        mirror.presence = Present()
        for _ in 0..<300 where !isLoaded(mirror.workspaces) { try await Task.sleep(for: .milliseconds(100)) }
        guard case .ready(let welcome) = model.session else { Issue.record("no session: \(model.session)"); return }
        #expect(welcome.protocolVersion == 1)
        #expect(welcome.methods.contains("workspaces.list"))

        // Only what the desktop opened to the phone (§7.5), and which one it has open.
        guard case .loaded(let workspaces) = mirror.workspaces else { Issue.record("\(mirror.workspaces)"); return }
        #expect(workspaces.map(\.name) == ["snotra", "website"])
        let snotra = try #require(workspaces.first { $0.name == "snotra" }), website = try #require(workspaces.first { $0.name == "website" })
        #expect(mirror.activeWorkspaceId == snotra.id)

        await mirror.refreshChats(snotra.id)
        guard case .loaded(let chats) = mirror.chats[snotra.id] else { Issue.record("\(String(describing: mirror.chats[snotra.id]))"); return }
        #expect(chats.map(\.title) == ["Release notes for 1.4", "Why does the sandbox refuse git push?"])
        #expect(chats.first?.messageCount == 12)

        // #38: open a chat and follow a turn as it streams; the stored answer replaces the assembled one.
        let chat = mirror.chat(ChatRoute(chatId: chats[0].chatId, workspaceId: snotra.id, title: chats[0].title))
        mirror.attach(chat)
        await chat.open()
        #expect(chat.transcript.messages.count == 12)
        #expect(await chat.send("Write the release notes") == nil)
        var sawLive = false
        for _ in 0..<200 where chat.transcript.isRunning || chat.transcript.hasProvisionalAnswer {
            if chat.transcript.live?.text.isEmpty == false { sawLive = true }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(sawLive)
        #expect(chat.transcript.messages.count == 14)
        #expect(chat.transcript.messages.last?.text == Self.answer)
        #expect(chat.transcript.messages.last?.toolLines.map(\.line) == ["Read CHANGELOG.md"])

        // A turn stopped from the phone (`run.abort`).
        #expect(await chat.send("Explain it slowly") == nil)
        for _ in 0..<200 where chat.transcript.live?.text.isEmpty != false { try await Task.sleep(for: .milliseconds(25)) }
        await chat.stop()
        for _ in 0..<200 where chat.transcript.isRunning || chat.transcript.hasProvisionalAnswer { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.transcript.messages.last?.interrupted == true)

        // #39: a card allowed from the phone behind Face ID, one denied, one the desktop answers.
        #expect(await chat.send("Release it, after my approval") == nil)
        for _ in 0..<200 where chat.transcript.openApprovals.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        let allowed = try #require(chat.transcript.openApprovals.first)
        #expect(allowed.targets.map(\.path) == ["scripts/release.sh"])
        #expect(allowed.preview?.text == "npm run release -- 1.4.0")
        #expect(allowed.options == ["allow-once", "deny"])
        #expect(await chat.respond(to: allowed.requestId, .allowOnce) == nil)
        for _ in 0..<200 where chat.transcript.isRunning || chat.transcript.hasProvisionalAnswer { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.transcript.messages.last?.text == Self.answer)

        #expect(await chat.send("Release it, approval needed") == nil)
        for _ in 0..<200 where chat.transcript.openApprovals.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        let denied = try #require(chat.transcript.openApprovals.first)
        #expect(await chat.respond(to: denied.requestId, .deny) == nil)
        for _ in 0..<200 where chat.transcript.isRunning || chat.transcript.hasProvisionalAnswer { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.transcript.messages.last?.text == "Not run: denied.")

        #expect(await chat.send("Release it, the desktop answers") == nil)
        for _ in 0..<200 where chat.transcript.openApprovals.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        let elsewhere = try #require(chat.transcript.openApprovals.first)
        var note: ApprovalOutcome?
        for _ in 0..<200 where note == nil {
            note = chat.transcript.approvals.first { $0.id == elsewhere.requestId }?.outcome
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(note == ApprovalOutcome(kind: .denied, by: .desktop))
        // Too late from the phone: the card is no longer open.
        #expect(await chat.respond(to: elsewhere.requestId, .deny) == nil)
        for _ in 0..<200 where chat.transcript.isRunning || chat.transcript.hasProvisionalAnswer { try await Task.sleep(for: .milliseconds(25)) }
        mirror.detach(chat)
        await chat.close()

        // A new chat: nothing at the desktop until its first question, then opened and followed.
        let route = try await mirror.newChat(in: snotra.id)
        let fresh = mirror.chat(route)
        mirror.attach(fresh)
        #expect(await fresh.send("Hello") == nil)
        for _ in 0..<200 where fresh.transcript.isRunning || fresh.transcript.hasProvisionalAnswer { try await Task.sleep(for: .milliseconds(25)) }
        #expect(fresh.transcript.messages.map(\.role) == [.user, .assistant])
        #expect(fresh.transcript.messages.last?.text == Self.answer)
        mirror.detach(fresh)

        // The switch (`workspace.activate`), and the desktop's `state` that follows it.
        #expect(await mirror.activate(website.id) == nil)
        #expect(mirror.activeWorkspaceId == website.id)
        await mirror.refreshChats(website.id)
        guard case .loaded(let websiteChats) = mirror.chats[website.id] else { Issue.record("no chats"); return }
        for _ in 0..<50 where mirror.state(of: websiteChats[0]) != .running { try await Task.sleep(for: .milliseconds(100)) }
        #expect(mirror.state(of: websiteChats[0]) == .running)

        // A turn runs at the desktop now: switching back is refused (R6).
        #expect(await mirror.activate(snotra.id) == .running)
        #expect(mirror.activeWorkspaceId == website.id)

        await model.unpair()
        #expect(model.pairing == nil)
    }

    /// Face ID, always confirmed.
    struct Present: UserPresence {
        var canConfirm: Bool { true }
        func confirm(_ reason: String) async -> Bool { true }
    }

    /// What the harness's turns answer.
    static let answer = "Here are the notes for **1.4**:\n\n```sh\nnpm run release -- 1.4.0\n```\n\nGrüße aus Snotra — fertig."

    private func isPaired(_ step: PairingFlow.Step) -> Bool {
        if case .paired = step { true } else { false }
    }

    private func isLoaded(_ workspaces: DesktopMirror.Loadable<[DesktopMirror.Workspace]>) -> Bool {
        if case .loaded = workspaces { true } else { false }
    }
}

/// What the desktop harness wrote: the relay stand-in's configuration and the key to type.
struct DesktopHarness: Decodable {
    let relayHost: String
    let relayUrl: URL
    let databaseUrl: URL
    let identityToolkitUrl: URL
    let apiKey: String
    let appCheckToken: String
    let typedKey: String

    var endpoint: RelayEndpoint {
        RelayEndpoint(host: relayHost, relayURL: relayUrl, databaseURL: databaseUrl,
                      identityToolkitURL: identityToolkitUrl, apiKey: apiKey, appCheck: .debugToken(appCheckToken))
    }

    static var fixture: DesktopHarness? {
        guard let path = ProcessInfo.processInfo.environment["SNOTRA_DESKTOP_HARNESS"],
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return try? JSONDecoder().decode(DesktopHarness.self, from: data)
    }
}
