import SwiftUI

/// The entry point to pairing. Until the protocol specifies the flow (QR scan,
/// typed key, confirmation on the desktop — concept §5.1), it only says that
/// pairing is not available yet.
struct PairingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Pairing isn't available yet", systemImage: "qrcode.viewfinder")
            } description: {
                Text("It arrives together with remote access in Snotra on your desktop.")
            }
            .navigationTitle("Pair with your desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    PairingView()
}
