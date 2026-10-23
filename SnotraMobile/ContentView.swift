import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPairingPresented = false
    @State private var isDisconnectConfirming = false
    @State private var model = RemoteModel()
    @State private var network = NetworkMonitor()

    var body: some View {
        Group {
            if model.pairing != nil {
                paired
            } else {
                notPaired
            }
        }
        .background(Color.background)
        .sheet(isPresented: $isPairingPresented, onDismiss: {
            model.reload()
            if scenePhase == .active { model.activate() }
        }) {
            PairingView()
        }
        .task { model.reload() }
        .onChange(of: network.isAvailable) { _, available in
            // Back online: connect now rather than after the channel's back-off.
            if available, scenePhase == .active { Task { await model.reconnect() } }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.activate()
            } else {
                Task { await model.deactivate() }
            }
        }
    }

    private var paired: some View {
        Group {
            let display = ConnectionDisplay(model.connection, session: model.session, networkAvailable: network.isAvailable)
            if display == .connected, let mirror = model.mirror {
                WorkspacesView(mirror: mirror, onDisconnect: { isDisconnectConfirming = true })
            } else {
                PairedView(
                    display: display,
                    onTryNow: { Task { await model.reconnect() } },
                    onDisconnect: { isDisconnectConfirming = true })
            }
        }
        .confirmationDialog("Disconnect this iPhone?", isPresented: $isDisconnectConfirming, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task { await model.unpair() }
            }
        } message: {
            Text("Snotra on your desktop can no longer reach it. To use it again, pair it anew.")
        }
    }

    private var notPaired: some View {
        ContentUnavailableView {
            if model.notice == .removedAtDesktop {
                Label("Removed on your desktop", systemImage: "iphone.slash")
            } else {
                Label("Not paired", systemImage: "iphone.and.arrow.forward")
            }
        } description: {
            if model.notice == .removedAtDesktop {
                Text("Snotra on your desktop no longer knows this iPhone. Pair it again to follow and drive its chats.")
            } else {
                Text("Pair this iPhone with Snotra on your desktop to follow and drive its chats.")
            }
        } actions: {
            Button("Start pairing") {
                isPairingPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .foregroundStyle(Color.onAccent)
            .accessibilityIdentifier("startPairing")
        }
    }
}

#Preview {
    ContentView()
}
