import SwiftUI

struct PrivacyShieldView: View {
    let shield: PrivacyShield

    var body: some View {
        ZStack {
            Color.background
                .ignoresSafeArea()
            switch shield {
            case .captured:
                ContentUnavailableView {
                    Label("Hidden while your screen is shared", systemImage: "eye.slash")
                } description: {
                    Text("Snotra shows nothing while the screen is recorded, mirrored or shared.")
                }
            case .inactive:
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("privacyShield")
    }
}

#Preview("Captured") {
    PrivacyShieldView(shield: .captured)
}

#Preview("Inactive") {
    PrivacyShieldView(shield: .inactive)
}
