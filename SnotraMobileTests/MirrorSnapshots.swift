import SwiftUI
import Testing
import UIKit
@testable import SnotraMobile

/// The workspace and chat screens as pictures, light and dark, at the default
/// and the largest accessibility text size, in English and German. Lists need
/// a window to draw in, so these are hosted in one rather than rendered with
/// `ImageRenderer`. Off unless `SNOTRA_SNAPSHOT_DIR` names a folder, as for
/// `ConnectionSnapshots`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"] != nil))
@MainActor
struct MirrorSnapshots {
    @Test func writesTheMirrorScreens() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mirror = DesktopMirror.preview
        await mirror.sessionStarted()
        await mirror.refreshChats("w2")
        let empty = DesktopMirror { method, _ throws(RemoteCallError) in
            method == "workspaces.list" ? .object(["workspaces": .array([])]) : .object(["chats": .array([])])
        }
        await empty.sessionStarted()

        let screens: [(String, AnyView)] = [
            ("workspaces", AnyView(WorkspacesView(mirror: mirror))),
            ("workspaces-empty", AnyView(WorkspacesView(mirror: empty))),
            ("chats", AnyView(NavigationStack { ChatsView(mirror: mirror, workspaceId: "w2") })),
            ("chats-active", AnyView(NavigationStack { ChatsView(mirror: mirror, workspaceId: "w1") })),
        ]
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        for (name, screen) in screens {
            for (scheme, schemeName) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                for (size, sizeName) in [(DynamicTypeSize.large, "default"), (.accessibility3, "ax3")] {
                    for language in ["en", "de"] {
                        window.rootViewController = UIHostingController(rootView: screen
                            .background(Color.background)
                            .environment(\.colorScheme, scheme)
                            .environment(\.dynamicTypeSize, size)
                            .environment(\.locale, Locale(identifier: language)))
                        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                        window.makeKeyAndVisible()
                        // Long enough for `.task` to have read the chats and the list to have laid out.
                        try await Task.sleep(for: .milliseconds(400))
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        try #require(image.pngData()).write(
                            to: folder.appending(path: "mirror-\(name)-\(schemeName)-\(sizeName)-\(language).png"))
                    }
                }
            }
        }
        window.isHidden = true
    }
}
