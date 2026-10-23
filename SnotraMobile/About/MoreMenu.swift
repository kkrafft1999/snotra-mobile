import SwiftUI

/// The menu at the top right of every screen outside the pairing sheet:
/// *About Snotra* always, *Disconnect* once the phone is paired.
struct MoreMenu: ToolbarContent {
    var onAbout: () -> Void
    var onDisconnect: (() -> Void)?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("About Snotra", systemImage: "info.circle", action: onAbout)
                    .accessibilityIdentifier("about")
                if let onDisconnect {
                    Divider()
                    Button("Disconnect", systemImage: "iphone.slash", role: .destructive, action: onDisconnect)
                        .accessibilityIdentifier("disconnect")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("more")
        }
    }
}
