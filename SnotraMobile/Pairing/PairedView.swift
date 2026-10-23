import SwiftUI

/// The paired phone's screen until the chats arrive (#37): one state of the
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
            if display == .relayUnreachable {
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
        }
    }

    private var message: LocalizedStringResource {
        switch display {
        case .connecting: "Your chats appear here once the connection stands."
        case .connected: "Following and driving chats arrives in a later version."
        case .desktopOffline: "Snotra on your desktop isn't running or has no connection. It shows up here again as soon as it's back."
        case .relayUnreachable: "The app keeps trying. Snotra's relay may be down for a moment."
        case .noNetwork: "Connect this iPhone to Wi-Fi or mobile data. The app reconnects by itself."
        }
    }

    private var symbol: String {
        switch display {
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "desktopcomputer"
        case .desktopOffline: "desktopcomputer.trianglebadge.exclamationmark"
        case .relayUnreachable: "icloud.slash"
        case .noNetwork: "wifi.slash"
        }
    }
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
