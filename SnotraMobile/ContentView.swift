import SwiftUI

struct ContentView: View {
    @State private var isPairingPresented = false
    @State private var pairing: PairingRecord?
    var pairingStore = PairingStore()

    var body: some View {
        Group {
            if pairing != nil {
                ContentUnavailableView {
                    Label("Paired with your desktop", systemImage: "iphone.and.arrow.forward")
                } description: {
                    Text("Following and driving chats arrives in a later version.")
                }
            } else {
                notPaired
            }
        }
        .background(Color.background)
        .sheet(isPresented: $isPairingPresented, onDismiss: reload) {
            PairingView()
        }
        .task { reload() }
    }

    private var notPaired: some View {
        ContentUnavailableView {
            Label("Not paired", systemImage: "iphone.and.arrow.forward")
        } description: {
            Text("Pair this iPhone with Snotra on your desktop to follow and drive its chats.")
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

    private func reload() {
        pairing = try? pairingStore.load()
    }
}

#Preview {
    ContentView()
}
