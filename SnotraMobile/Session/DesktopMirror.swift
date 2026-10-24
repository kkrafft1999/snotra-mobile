import Foundation
import Observation

/// What the phone shows of the desktop (concept §1): the workspaces opened to
/// it, which one the desktop has open, and the chats of each. A mirror, not a
/// copy — it lives in memory only and is read again for every new session.
@MainActor @Observable
final class DesktopMirror {
    struct Workspace: Decodable, Identifiable, Equatable, Sendable {
        let workspaceId: String
        /// The folder's name, never its path (remote-interface.md §8.1).
        let name: String
        var active: Bool

        var id: String { workspaceId }
    }

    enum ChatState: String, Decodable, Sendable {
        case idle
        case running
        case needsApproval = "needs-approval"
    }

    struct Chat: Decodable, Identifiable, Equatable, Sendable {
        let chatId: String
        var title: String
        /// Milliseconds since 1970, as the desktop keeps it.
        let updatedAt: Double
        let messageCount: Int
        let state: ChatState

        var id: String { chatId }
        var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chatId = try container.decode(String.self, forKey: .chatId)
            title = try container.decode(String.self, forKey: .title)
            updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
            messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
            // A state this app does not know yet shows as idle rather than failing the list.
            state = (try? container.decode(ChatState.self, forKey: .state)) ?? .idle
        }

        private enum CodingKeys: String, CodingKey { case chatId, title, updatedAt, messageCount, state }
    }

    enum Loadable<Value: Equatable>: Equatable {
        case loading
        case loaded(Value)
        case failed(RemoteCallError)
    }

    /// Why the desktop did not switch to a workspace (`workspace.activate`, §8.1).
    enum SwitchRefusal: Equatable {
        /// A chat is running or waiting for an approval (R6).
        case running
        /// The file on show at the desktop has unsaved changes.
        case unsavedChanges
        /// The workspace is no longer open to the phone, or the desktop could not open it.
        case notAvailable
        /// The desktop did not answer, or could not switch for another reason.
        case other
    }

    private(set) var workspaces: Loadable<[Workspace]> = .loading
    private(set) var chats: [Workspace.ID: Loadable<[Chat]>] = [:]
    /// The workspace being switched to at the desktop.
    private(set) var switching: Workspace.ID?
    /// The chats running or waiting at the desktop, from its last `state`; nil before the first.
    private var runningChats: [String: ChatState]?
    /// The chats on screen, which hear their events.
    private var openChats: [String: ChatModel] = [:]

    typealias Call = @MainActor (String, JSONValue) async throws(RemoteCallError) -> JSONValue
    private let call: Call
    /// Who confirms an answer that lets the agent act; the chats opened from here on ask it.
    @ObservationIgnored var presence: any UserPresence = DeviceOwnerPresence()

    init(call: @escaping Call) {
        self.call = call
    }

    /// The workspaces came in at least once.
    var hasLoaded: Bool {
        if case .loaded = workspaces { true } else { false }
    }

    var activeWorkspaceId: Workspace.ID? {
        if case .loaded(let list) = workspaces { list.first(where: \.active)?.id } else { nil }
    }

    func workspace(_ id: Workspace.ID) -> Workspace? {
        if case .loaded(let list) = workspaces { list.first { $0.id == id } } else { nil }
    }

    /// A chat's state as of the desktop's last `state` event, else as the list said.
    func state(of chat: Chat) -> ChatState {
        runningChats.map { $0[chat.chatId] ?? .idle } ?? chat.state
    }

    /// A new session stands: everything shown is read again (§17, a new session is a new connection).
    func sessionStarted() async {
        await refreshWorkspaces()
        for id in chats.keys { await refreshChats(id) }
        for chat in openChats.values { await chat.sessionStarted() }
    }

    /// A chat for its screen; it hears its events while attached.
    func chat(_ route: ChatRoute) -> ChatModel {
        openChats[route.chatId]
            ?? ChatModel(chatId: route.chatId, workspaceId: route.workspaceId, title: route.title, isNew: route.isNew,
                         presence: presence, call: call)
    }

    /// `chat.new` in the workspace open at the desktop. Nothing exists there until the first question.
    func newChat(in workspaceId: Workspace.ID) async throws(RemoteCallError) -> ChatRoute {
        let answer = try await call("chat.new", .object(["workspaceId": .string(workspaceId)]))
        guard let chatId = answer["chatId"]?.stringValue else { throw .malformedAnswer }
        return ChatRoute(chatId: chatId, workspaceId: workspaceId, isNew: true)
    }

    func attach(_ chat: ChatModel) {
        openChats[chat.chatId] = chat
    }

    func detach(_ chat: ChatModel) {
        if openChats[chat.chatId] === chat { openChats[chat.chatId] = nil }
    }

    func refreshWorkspaces() async {
        do throws(RemoteCallError) {
            struct Answer: Decodable { let workspaces: [Workspace] }
            let answer = try await call("workspaces.list", .object([:])).decoded(as: Answer.self)
            workspaces = .loaded(answer.workspaces)
            // Chats of a workspace that is no longer open to the phone are forgotten.
            let known = Set(answer.workspaces.map(\.id))
            chats = chats.filter { known.contains($0.key) }
        } catch {
            // What is on screen stays while a refresh fails; only nothing at all is an error.
            if case .loaded = workspaces { return }
            workspaces = .failed(error)
        }
    }

    func refreshChats(_ workspaceId: Workspace.ID) async {
        if chats[workspaceId] == nil { chats[workspaceId] = .loading }
        do throws(RemoteCallError) {
            struct Answer: Decodable { let chats: [Chat] }
            let params = JSONValue.object(["workspaceId": .string(workspaceId), "limit": .number(200)])
            chats[workspaceId] = .loaded(try await call("chats.list", params).decoded(as: Answer.self).chats)
        } catch {
            if error.reason == "not-found" {
                chats[workspaceId] = nil
                await refreshWorkspaces()
                return
            }
            if case .loaded = chats[workspaceId] { return }
            chats[workspaceId] = .failed(error)
        }
    }

    /// Switches the desktop to a workspace (`workspace.activate`); nil once it did.
    func activate(_ workspaceId: Workspace.ID) async -> SwitchRefusal? {
        guard switching == nil else { return .other }
        switching = workspaceId
        defer { switching = nil }
        do throws(RemoteCallError) {
            _ = try await call("workspace.activate", .object(["workspaceId": .string(workspaceId)]))
            markActive(workspaceId)
            return nil
        } catch {
            switch (error.reason, error) {
            case ("busy", .desktop(_, _, _, let why)) where why == "running": return .running
            case ("busy", .desktop(_, _, _, let why)) where why == "unsaved-changes": return .unsavedChanges
            case ("not-found", _):
                await refreshWorkspaces()
                return .notAvailable
            default: return .other
            }
        }
    }

    /// An event of the desktop (remote-interface.md §8.2).
    func apply(_ method: String, _ params: JSONValue) async {
        switch method {
        case "state":
            if case .array(let running) = params["running"] {
                var states: [String: ChatState] = [:]
                for entry in running {
                    guard let chatId = entry["chatId"]?.stringValue else { continue }
                    states[chatId] = entry["state"]?.stringValue.flatMap(ChatState.init(rawValue:)) ?? .running
                }
                runningChats = states
            }
            if let active = params["activeWorkspaceId"] {
                markActive(active.stringValue)
            }
        case "chat.updated":
            guard let chatId = params["chatId"]?.stringValue, let title = params["title"]?.stringValue else { return }
            for (workspaceId, list) in chats {
                guard case .loaded(var rows) = list, let index = rows.firstIndex(where: { $0.chatId == chatId }) else { continue }
                rows[index].title = title
                chats[workspaceId] = .loaded(rows)
            }
        case "session.resync":
            await sessionStarted()
            return
        default:
            break
        }
        if method.hasPrefix("chat.") || method.hasPrefix("approval."), let chatId = params["chatId"]?.stringValue, let chat = openChats[chatId] {
            chat.apply(method, params)
        }
        switch method {
        case "chat.progress" where params["type"]?.stringValue == "run-end":
            // The list's message counts and order changed with the turn.
            for (workspaceId, list) in chats {
                if case .loaded(let rows) = list, rows.contains(where: { $0.chatId == params["chatId"]?.stringValue }) {
                    Task { await refreshChats(workspaceId) }
                }
            }
        default:
            break
        }
    }

    private func markActive(_ workspaceId: Workspace.ID?) {
        guard case .loaded(var list) = workspaces else { return }
        for index in list.indices { list[index].active = list[index].id == workspaceId }
        workspaces = .loaded(list)
    }
}

/// Where a chat's screen is, for the navigation stack.
struct ChatRoute: Hashable, Identifiable {
    let chatId: String
    let workspaceId: DesktopMirror.Workspace.ID
    var title = ""
    var isNew = false

    var id: String { chatId }
}
