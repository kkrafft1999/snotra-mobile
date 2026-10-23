import Foundation
import Network
import Observation

/// What the paired screen shows (concept §8: every state has its own screen
/// or note), from the channel's state, the session's and whether the phone has
/// a network.
enum ConnectionDisplay: Equatable, CaseIterable {
    case connecting
    /// The session stands: the desktop's workspaces take the screen.
    case connected
    case desktopOffline
    case relayUnreachable
    case noNetwork
    /// The desktop is there, but no handshake got through (spec §16).
    case cannotConnect
    case updateApp
    case updateDesktop

    init(_ state: RelayConnectionState?, session: RemoteSession.Status = .idle, networkAvailable: Bool) {
        // Without a network the channel's last state is stale; say what the phone knows.
        guard networkAvailable else {
            self = .noNetwork
            return
        }
        switch state {
        case .connected(desktopOnline: true):
            switch session {
            case .ready: self = .connected
            case .failed: self = .cannotConnect
            case .incompatible(let updateApp): self = updateApp ? .updateApp : .updateDesktop
            case .idle, .handshaking: self = .connecting
            }
        case .connected(desktopOnline: false): self = .desktopOffline
        case .unreachable: self = .relayUnreachable
        // `.ended` lasts only until the model has forgotten the pairing.
        case nil, .connecting, .ended: self = .connecting
        }
    }
}

/// Whether the phone has a path to the internet at all (Network framework).
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isAvailable = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.isAvailable = available }
        }
        monitor.start(queue: DispatchQueue(label: "dev.snotra-ai.mobile.network"))
    }

    deinit {
        monitor.cancel()
    }
}
