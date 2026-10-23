import Foundation
import Observation

/// The phone's pairing once it exists: the channel while the app is in the
/// foreground, *Disconnect* on the phone, and the end that comes from the
/// desktop (concept §5.3). One pairing, one channel at a time.
@MainActor @Observable
final class RemoteModel {
    /// Why the phone is no longer paired, when it did not choose so itself.
    enum Notice: Equatable {
        /// *Remove phone* at the desktop, a new pairing there, or the relay's clean-up.
        case removedAtDesktop
    }

    private(set) var pairing: PairingRecord?
    private(set) var connection: RelayConnectionState?
    private(set) var notice: Notice?

    private let relays: [RelayEndpoint]
    private let transport: any RelayTransport
    private let keyStore: DeviceKeyStore
    private let pairingStore: PairingStore
    private let timing: RelayChannel.Timing
    private var channel: RelayChannel?
    private var watching: Task<Void, Never>?

    init(relays: [RelayEndpoint] = RelayEndpoint.builtIn,
         transport: any RelayTransport = URLSessionTransport(),
         keyStore: DeviceKeyStore = DeviceKeyStore(),
         pairingStore: PairingStore = PairingStore(),
         timing: RelayChannel.Timing = RelayChannel.Timing()) {
        self.relays = relays
        self.transport = transport
        self.keyStore = keyStore
        self.pairingStore = pairingStore
        self.timing = timing
    }

    /// Reads the pairing again, as after the pairing sheet closes.
    func reload() {
        pairing = try? pairingStore.load()
        if pairing != nil { notice = nil }
    }

    /// The app came to the foreground: connect (spec §12, "every time a side connects").
    func activate() {
        guard channel == nil, let pairing, let client = client(for: pairing),
              let keys = try? keyStore.load()
        else { return }
        let channel = RelayChannel(client: client, channelId: pairing.channelId, timing: timing) { [keys] in
            try keys.sign($0)
        }
        self.channel = channel
        connection = .connecting
        watching = Task { [weak self] in
            for await event in channel.events {
                guard case .state(let state) = event else { continue }
                self?.connection = state
                if state == .ended { await self?.endedAtDesktop() }
            }
        }
        Task { await channel.start() }
    }

    /// The app left the foreground: the channel and the phone's presence go.
    func deactivate() async {
        let channel = self.channel
        self.channel = nil
        watching?.cancel()
        watching = nil
        connection = nil
        await channel?.stop()
    }

    /// *Disconnect* (§5.8): the channel is deleted at the relay, so that the
    /// desktop hears of it, and the phone forgets the pairing and its keys. When
    /// the relay cannot be reached the phone forgets them all the same; the
    /// relay's clean-up removes a channel nobody has seen for 30 days.
    func unpair() async {
        guard let pairing else { return }
        await deactivate()
        if let client = client(for: pairing), let keys = try? keyStore.load() {
            if let session = try? await client.phoneSession(channelId: pairing.channelId, sign: { [keys] in try keys.sign($0) }) {
                try? await client.deleteChannel(pairing.channelId, idToken: session.idToken)
            }
        }
        forget()
    }

    private func endedAtDesktop() async {
        await deactivate()
        forget()
        notice = .removedAtDesktop
    }

    private func forget() {
        try? pairingStore.delete()
        try? keyStore.delete()
        pairing = nil
    }

    private func client(for pairing: PairingRecord) -> RelayClient? {
        relays.first { $0.host == pairing.relayHost }.map { RelayClient(endpoint: $0, transport: transport) }
    }
}
