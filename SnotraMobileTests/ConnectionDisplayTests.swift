import SwiftUI
import Testing
import UIKit
@testable import SnotraMobile

struct ConnectionDisplayTests {
    @Test func eachChannelStateHasItsScreen() {
        #expect(ConnectionDisplay(nil, networkAvailable: true) == .connecting)
        #expect(ConnectionDisplay(.connecting, networkAvailable: true) == .connecting)
        #expect(ConnectionDisplay(.connected(desktopOnline: true), networkAvailable: true) == .connecting)
        #expect(ConnectionDisplay(.connected(desktopOnline: false), networkAvailable: true) == .desktopOffline)
        #expect(ConnectionDisplay(.unreachable, networkAvailable: true) == .relayUnreachable)
        #expect(ConnectionDisplay(.ended, networkAvailable: true) == .connecting)
    }

    @Test func withTheDesktopOnlineTheSessionDecides() {
        let welcome = SessionHello.Welcome(protocolVersion: 1, connectionId: "c", methods: [])
        let online = RelayConnectionState.connected(desktopOnline: true)
        #expect(ConnectionDisplay(online, session: .idle, networkAvailable: true) == .connecting)
        #expect(ConnectionDisplay(online, session: .handshaking, networkAvailable: true) == .connecting)
        #expect(ConnectionDisplay(online, session: .ready(welcome), networkAvailable: true) == .connected)
        #expect(ConnectionDisplay(online, session: .failed, networkAvailable: true) == .cannotConnect)
        #expect(ConnectionDisplay(online, session: .incompatible(updateApp: true), networkAvailable: true) == .updateApp)
        #expect(ConnectionDisplay(online, session: .incompatible(updateApp: false), networkAvailable: true) == .updateDesktop)
        // A session the channel no longer carries counts for nothing.
        #expect(ConnectionDisplay(.connected(desktopOnline: false), session: .ready(welcome), networkAvailable: true) == .desktopOffline)
        #expect(ConnectionDisplay(.unreachable, session: .ready(welcome), networkAvailable: true) == .relayUnreachable)
    }

    @Test func theWorkspacesStayWhileAConnectionThatStoodComesBack() {
        #expect(ConnectionDisplay.connected.showsMirror(hasLoaded: false))
        #expect(ConnectionDisplay.connecting.showsMirror(hasLoaded: true))
        // The very first connection has nothing to keep on screen.
        #expect(!ConnectionDisplay.connecting.showsMirror(hasLoaded: false))
        // Everything that needs the person's attention gets its own screen.
        for display in ConnectionDisplay.allCases where ![.connected, .connecting].contains(display) {
            #expect(!display.showsMirror(hasLoaded: true))
        }
    }

    @Test func noNetworkWinsOverWhatTheChannelLastSaid() {
        for state in [nil, .connecting, .connected(desktopOnline: true), .connected(desktopOnline: false), .unreachable] as [RelayConnectionState?] {
            #expect(ConnectionDisplay(state, networkAvailable: false) == .noNetwork)
        }
    }
}

/// Every state as a picture, light and dark, at the default and the largest
/// accessibility text size, in English and German — for a person (or an agent
/// without a simulator window) to look at. Off unless `SNOTRA_SNAPSHOT_DIR`
/// names a folder (`TEST_RUNNER_SNOTRA_SNAPSHOT_DIR` for `xcodebuild test`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"] != nil))
@MainActor
struct ConnectionSnapshots {
    @Test func writesEveryState() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for display in ConnectionDisplay.allCases {
            for (scheme, schemeName) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                for (size, sizeName) in [(DynamicTypeSize.large, "default"), (.accessibility3, "ax3")] {
                    for language in ["en", "de"] {
                        let view = PairedView(display: display)
                            .frame(width: 393, height: 852)
                            .background(Color.background)
                            .environment(\.colorScheme, scheme)
                            .environment(\.dynamicTypeSize, size)
                            .environment(\.locale, Locale(identifier: language))
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = 2
                        let image = try #require(renderer.uiImage)
                        try #require(image.pngData()).write(
                            to: folder.appending(path: "\(display)-\(schemeName)-\(sizeName)-\(language).png"))
                    }
                }
            }
        }
    }
}
