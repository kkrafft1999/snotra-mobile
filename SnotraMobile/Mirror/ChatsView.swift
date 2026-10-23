import SwiftUI

/// The chats of one workspace, newest first, and the switch that opens the
/// workspace on the desktop (`workspace.activate`).
struct ChatsView: View {
    let mirror: DesktopMirror
    let workspaceId: DesktopMirror.Workspace.ID
    @State private var refusal: DesktopMirror.SwitchRefusal?

    var body: some View {
        Group {
            if let workspace = mirror.workspace(workspaceId) {
                list(workspace)
                    .navigationTitle(workspace.name)
            } else {
                ContentUnavailableView {
                    Label("No longer open to this iPhone", systemImage: "folder.badge.minus")
                } description: {
                    Text("Snotra on your desktop closed this workspace to your phone.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await mirror.refreshChats(workspaceId) }
        .refreshable { await mirror.refreshChats(workspaceId) }
        .alert(refusalTitle, isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusalMessage)
        }
    }

    private func list(_ workspace: DesktopMirror.Workspace) -> some View {
        List {
            Section {
                if workspace.active {
                    Label("Open on your desktop", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace.active")
                } else {
                    Button {
                        Task { refusal = await mirror.activate(workspaceId) }
                    } label: {
                        HStack {
                            Label("Open it on your desktop", systemImage: "desktopcomputer")
                            Spacer()
                            if mirror.switching == workspaceId { ProgressView() }
                        }
                    }
                    .disabled(mirror.switching != nil)
                    .accessibilityIdentifier("workspace.activate")
                }
            } footer: {
                if !workspace.active {
                    Text("Your desktop has another workspace open. This switches it over.")
                }
            }

            switch mirror.chats[workspaceId] ?? .loading {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't load the chats", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Snotra on your desktop didn't answer in time. Pull down to try again.")
                }
                .listRowBackground(Color.clear)
            case .loaded(let chats) where chats.isEmpty:
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Chats you start in this workspace on your desktop appear here.")
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("chats.empty")
            case .loaded(let chats):
                Section("Chats") {
                    ForEach(chats) { chat in
                        ChatRow(chat: chat, state: mirror.state(of: chat))
                    }
                }
                .accessibilityIdentifier("chats")
            }
        }
    }

    private var refusalTitle: LocalizedStringResource {
        switch refusal {
        case .running: "A chat is still running"
        case .unsavedChanges: "Unsaved changes on your desktop"
        case .notAvailable: "Workspace not available"
        case .other, nil: "Couldn't switch the workspace"
        }
    }

    private var refusalMessage: LocalizedStringResource {
        switch refusal {
        case .running: "Snotra on your desktop is working on a chat or waiting for an approval. Switch once it's done."
        case .unsavedChanges: "A file open on your desktop has unsaved changes. Save or discard them there first."
        case .notAvailable: "Snotra on your desktop could not open this workspace, or no longer opens it to your phone."
        case .other, nil: "Snotra on your desktop didn't switch in time. Try again in a moment."
        }
    }
}

private struct ChatRow: View {
    let chat: DesktopMirror.Chat
    let state: DesktopMirror.ChatState
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // At the accessibility sizes the time goes under the title, so that the title keeps the width.
            if typeSize.isAccessibilitySize {
                Text(chat.title)
                updated
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .lineLimit(2)
                    Spacer()
                    updated
                }
            }
            AnyLayout(typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))) {
                Text("\(chat.messageCount) messages")
                switch state {
                case .running:
                    Label("Running", systemImage: "circle.dotted")
                        .foregroundStyle(.tint)
                case .needsApproval:
                    Label("Waiting for your approval", systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.orange)
                case .idle:
                    EmptyView()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .combine)
    }

    private var updated: some View {
        Text(chat.updated, format: .relative(presentation: .named))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

extension DesktopMirror {
    /// A mirror that answers from memory, for previews and snapshots.
    static var preview: DesktopMirror {
        let now = Date().timeIntervalSince1970 * 1000
        let mirror = DesktopMirror { method, _ throws(RemoteCallError) in
            switch method {
            case "workspaces.list":
                return .object(["workspaces": .array([
                    .object(["workspaceId": "w1", "name": "snotra", "active": true]),
                    .object(["workspaceId": "w2", "name": "snotra-mobile", "active": false]),
                ])])
            case "chats.list":
                return .object(["chats": .array([
                    .object(["chatId": "c1", "title": "Release notes for 1.4", "updatedAt": .number(now - 60_000),
                             "messageCount": 12, "state": "running"]),
                    .object(["chatId": "c2", "title": "Why does the sandbox refuse git push?", "updatedAt": .number(now - 3_600_000),
                             "messageCount": 4, "state": "needs-approval"]),
                    .object(["chatId": "c3", "title": "Tidy up the README", "updatedAt": .number(now - 86_400_000 * 3),
                             "messageCount": 1, "state": "idle"]),
                ])])
            default:
                return .object([:])
            }
        }
        Task { await mirror.sessionStarted() }
        return mirror
    }
}

#Preview("Chats") {
    NavigationStack {
        ChatsView(mirror: .preview, workspaceId: "w2")
    }
}
