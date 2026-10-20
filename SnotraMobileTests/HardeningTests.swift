import Testing
import UIKit
@testable import SnotraMobile

struct PrivacyShieldTests {
    @Test func anActiveUncapturedAppShowsItsContent() {
        #expect(PrivacyShield.required(isActive: true, isCaptured: false) == nil)
    }

    @Test func anInactiveAppIsCovered() {
        #expect(PrivacyShield.required(isActive: false, isCaptured: false) == .inactive)
    }

    @Test func aCapturedScreenIsCoveredEvenWhileActive() {
        #expect(PrivacyShield.required(isActive: true, isCaptured: true) == .captured)
    }

    @Test func captureWinsOverInactive() {
        #expect(PrivacyShield.required(isActive: false, isCaptured: true) == .captured)
    }
}

@MainActor
struct KeyboardPolicyTests {
    @Test func thirdPartyKeyboardsAreRefused() {
        #expect(AppDelegate().application(.shared, shouldAllowExtensionPointIdentifier: .keyboard) == false)
    }
}

@MainActor
struct SceneShieldTests {
    @Test func theAppInstallsTheShieldAndItCoversTheSceneWhileNotActive() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let controller = try #require(PrivacyShieldController.installed(on: scene))
        #expect(PrivacyShieldController.install(on: scene) === controller)

        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(controller.window.isHidden == false)

        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(controller.window.isHidden)
    }
}
