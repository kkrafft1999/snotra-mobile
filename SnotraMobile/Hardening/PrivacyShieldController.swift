import SwiftUI
import UIKit

/// Lays the privacy shield over a whole scene, in a window of its own.
///
/// A window above SwiftUI's covers sheets and alerts too, which an overlay on
/// the root view would not, so a screen added later cannot forget the shield.
/// SwiftUI keeps the scene delegate to itself, so the controller follows the
/// scene through its notifications and its capture trait instead.
@MainActor
final class PrivacyShieldController {
    private static var controllers: [ObjectIdentifier: PrivacyShieldController] = [:]

    let window: UIWindow
    // Starts as active: before the scene has ever been active it shows nothing
    // worth hiding, and the shield would only flash at launch.
    private var isActive = true

    /// Installs the shield on `scene` once; later calls return the same one.
    @discardableResult
    static func install(on scene: UIWindowScene) -> PrivacyShieldController {
        if let controller = installed(on: scene) {
            return controller
        }
        let controller = PrivacyShieldController(scene: scene)
        controllers[ObjectIdentifier(scene)] = controller
        return controller
    }

    static func installed(on scene: UIWindowScene) -> PrivacyShieldController? {
        controllers[ObjectIdentifier(scene)]
    }

    private init(scene: UIWindowScene) {
        window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: PrivacyShieldView(shield: .inactive))
        window.isHidden = true

        let center = NotificationCenter.default
        center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sceneActivityChanged(isActive: true) }
        }
        center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sceneActivityChanged(isActive: false) }
        }
        center.addObserver(forName: UIScene.didDisconnectNotification, object: scene, queue: .main) { _ in
            MainActor.assumeIsolated { Self.controllers[ObjectIdentifier(scene)] = nil }
        }
        scene.registerForTraitChanges([UITraitSceneCaptureState.self]) { [weak self] (_: UIWindowScene, _) in
            self?.update()
        }
        update()
    }

    private func sceneActivityChanged(isActive: Bool) {
        self.isActive = isActive
        update()
    }

    private func update() {
        let isCaptured = window.windowScene?.traitCollection.sceneCaptureState == .active
        guard let shield = PrivacyShield.required(isActive: isActive, isCaptured: isCaptured) else {
            window.isHidden = true
            return
        }
        (window.rootViewController as? UIHostingController<PrivacyShieldView>)?.rootView = PrivacyShieldView(shield: shield)
        window.isHidden = false
    }
}

/// Installs the privacy shield on the scene its view ends up in.
struct PrivacyShieldInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView {
        InstallerView()
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene {
                PrivacyShieldController.install(on: scene)
            }
        }
    }
}
