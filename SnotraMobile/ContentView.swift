import SwiftUI

struct ContentView: View {
    @State private var isPairingPresented = false

    var body: some View {
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
            .accessibilityIdentifier("startPairing")
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingView()
        }
    }
}

#Preview {
    ContentView()
}
