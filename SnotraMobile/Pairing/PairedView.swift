import SwiftUI

/// The paired phone's screen while no session stands: one state of the
/// connection at a time, each with what happened and what the person can do.
struct PairedView: View {
    let display: ConnectionDisplay
    var onTryNow: () -> Void = {}
    var onDisconnect: () -> Void = {}

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
                .symbolEffect(.pulse, isActive: display == .connecting)
        } description: {
            Text(message)
        } actions: {
            if display == .connecting {
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("connecting")
            }
            if [.relayUnreachable, .cannotConnect, .updateDesktop].contains(display) {
                Button("Try now", action: onTryNow)
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.onAccent)
                    .accessibilityIdentifier("tryNow")
            }
            Button("Disconnect", role: .destructive, action: onDisconnect)
                .accessibilityIdentifier("disconnect")
        }
        .accessibilityIdentifier("connection.\(display)")
    }

    private var title: LocalizedStringResource {
        switch display {
        case .connecting: "Connecting to your desktop…"
        case .connected: "Connected to your desktop"
        case .desktopOffline: "Your desktop is offline"
        case .relayUnreachable: "Can't reach the relay"
        case .noNetwork: "No internet connection"
        case .cannotConnect: "Can't connect to your desktop"
        case .updateApp: "Update this app"
        case .updateDesktop: "Update Snotra on your desktop"
        }
    }

    private var message: LocalizedStringResource {
        switch display {
        case .connecting: "Your chats appear here once the connection stands."
        case .connected: "Your workspaces appear in a moment."
        case .desktopOffline: "Snotra on your desktop isn't running or has no connection. It shows up here again as soon as it's back."
        case .relayUnreachable: "The app keeps trying. Snotra's relay may be down for a moment."
        case .noNetwork: "Connect this iPhone to Wi-Fi or mobile data. The app reconnects by itself."
        case .cannotConnect: "Snotra on your desktop is online but doesn't answer this iPhone. Check that remote access is still on there, then try again."
        case .updateApp: "Snotra on your desktop speaks a newer version of the connection. Update Snotra for iPhone, then open it again."
        case .updateDesktop: "This app speaks a newer version of the connection than Snotra on your desktop. Update Snotra there, then try again."
        }
    }

    private var symbol: String {
        switch display {
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "desktopcomputer"
        case .desktopOffline: "desktopcomputer.trianglebadge.exclamationmark"
        case .relayUnreachable: "icloud.slash"
        case .noNetwork: "wifi.slash"
        case .cannotConnect: "lock.trianglebadge.exclamationmark"
        case .updateApp: "arrow.down.app"
        case .updateDesktop: "arrow.down.circle"
        }
    }
}

/// Above the desktop's workspaces while a connection that stood before comes
/// back: it takes a second or two, and without a sign the app seems to hang.
struct ReconnectingBar: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reconnecting…")
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reconnecting")
    }
}

#Preview("Reconnecting") {
    WorkspacesView(mirror: .preview)
        .safeAreaInset(edge: .top, spacing: 0) { ReconnectingBar() }
}

#Preview("Every state") {
    TabView {
        ForEach(ConnectionDisplay.allCases, id: \.self) { display in
            PairedView(display: display)
        }
    }
    .tabViewStyle(.page)
    .background(Color.background)
}
