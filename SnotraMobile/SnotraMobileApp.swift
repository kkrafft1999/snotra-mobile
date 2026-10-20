import SwiftUI

@main
struct SnotraMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(PrivacyShieldInstaller())
        }
    }
}
