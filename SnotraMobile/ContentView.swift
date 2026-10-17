import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Not paired", systemImage: "iphone.and.arrow.forward")
        } description: {
            Text("Pair this iPhone with Snotra on your desktop to follow and drive its chats.")
        }
    }
}

#Preview {
    ContentView()
}
