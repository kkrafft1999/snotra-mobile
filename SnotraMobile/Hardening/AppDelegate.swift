import UIKit

/// The app's UIKit hooks: what SwiftUI's `App` cannot express on its own.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Refuses third-party keyboards app-wide. A keyboard with full access may
    /// send what is typed to its maker; here that would be messages to the
    /// desktop, a typed pairing key or a safety phrase (#27). The system
    /// keyboard and dictation stay available.
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}
