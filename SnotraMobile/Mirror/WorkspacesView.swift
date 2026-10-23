import SwiftUI

/// The workspaces the desktop opened to this iPhone (concept §1), and which
/// one it has open. A workspace leads to its chats.
struct WorkspacesView: View {
    let mirror: DesktopMirror
    var onAbout: () -> Void = {}
    var onDisconnect: () -> Void = {}

    var body: some View {
        NavigationStack {
            content
                .scrollContentBackground(.hidden)
                .background(Color.background)
                .navigationTitle("Workspaces")
                .navigationDestination(for: DesktopMirror.Workspace.ID.self) { id in
                    ChatsView(mirror: mirror, workspaceId: id)
                }
                .navigationDestination(for: ChatRoute.self) { route in
                    ChatView(mirror: mirror, route: route)
                }
                .toolbar { MoreMenu(onAbout: onAbout, onDisconnect: onDisconnect) }
                .refreshable { await mirror.refreshWorkspaces() }
        }
    }

    @ViewBuilder private var content: some View {
        switch mirror.workspaces {
        case .loading:
            ProgressView("Loading workspaces…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load your workspaces", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Snotra on your desktop didn't answer in time.")
            } actions: {
                Button("Try again") { Task { await mirror.refreshWorkspaces() } }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.onAccent)
            }
        case .loaded(let workspaces) where workspaces.isEmpty:
            // A list, so that pulling down refreshes it once a workspace is opened at the desktop.
            List {
                ContentUnavailableView {
                    Label("No workspace open to this iPhone", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("In Snotra on your desktop, open the workspace and turn on “Access from your phone” under Settings › Security. Then pull down here.")
                }
                .listRowBackground(Color.clear)
            }
            .accessibilityIdentifier("workspaces.empty")
        case .loaded(let workspaces):
            List(workspaces) { workspace in
                NavigationLink(value: workspace.id) {
                    WorkspaceRow(workspace: workspace)
                }
            }
            .accessibilityIdentifier("workspaces")
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: DesktopMirror.Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(workspace.name, systemImage: workspace.active ? "folder.fill" : "folder")
            if workspace.active {
                Text("Open on your desktop")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Workspaces") {
    WorkspacesView(mirror: .preview)
}
