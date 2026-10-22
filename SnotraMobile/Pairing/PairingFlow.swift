import Foundation
import Observation

/// Part 1 of the protocol from the phone's side (spec §8, steps 15–37): from
/// the code the desktop shows to a paired channel the phone keeps.
@MainActor @Observable
final class PairingFlow {
    enum Step: Equatable {
        case entering
        /// Look-up and claim are on their way.
        case claiming
        /// Claimed; the person compares the words and chooses *Allow* at the desktop.
        case comparing(SafetyPhrase)
        case paired(PairingRecord)
        case failed(Failure)
    }

    /// What the person is told, after the outcomes of spec §8.
    enum Failure: Equatable {
        /// `invalid-*` before anything is sent.
        case invalidCode(PairingCode.Failure)
        /// A QR code from a relay this build does not ship with, or none to type a key for.
        case unknownRelay
        /// `404`: the code ran out or was used.
        case expired
        /// `401`, `429`, `503` or no network.
        case unreachable
        /// The channel vanished before `paired`: denied or cancelled at the desktop.
        case notAllowed
        /// A wrong `MAC_D`, or `paired` without one: the keys are not the desktop's.
        case notVerified
        /// The phone could not create or keep its keys.
        case keys
    }

    private(set) var step: Step = .entering

    private let relays: [RelayEndpoint]
    private let transport: any RelayTransport
    private let keyStore: DeviceKeyStore
    private let pairingStore: PairingStore
    private let wordList: SafetyPhrase.WordList
    private var running: Task<Void, Never>?
    /// The claimed channel and its token, so that *Cancel* can delete it.
    private var claimed: (client: RelayClient, channelId: Data, idToken: String)?

    init(relays: [RelayEndpoint] = RelayEndpoint.builtIn,
         transport: any RelayTransport = URLSessionTransport(),
         keyStore: DeviceKeyStore = DeviceKeyStore(),
         pairingStore: PairingStore = PairingStore(),
         wordList: SafetyPhrase.WordList) {
        self.relays = relays
        self.transport = transport
        self.keyStore = keyStore
        self.pairingStore = pairingStore
        self.wordList = wordList
    }

    /// A typed key goes to the first relay this build ships with (§4).
    func submit(typed key: String) {
        guard step == .entering else { return }
        guard let relay = relays.first else { return fail(.unknownRelay) }
        do {
            start(try PairingCode.parse(typed: key), at: relay)
        } catch {
            fail(.invalidCode(error))
        }
    }

    /// A scanned QR payload names its relay, which must be one this build ships with.
    func submit(scanned payload: String) {
        guard step == .entering else { return }
        do {
            let (host, code) = try PairingCode.parse(qr: payload, allowedHosts: Set(relays.map(\.host)))
            guard let relay = relays.first(where: { $0.host == host }) else { return fail(.unknownRelay) }
            start(code, at: relay)
        } catch .unknownRelay {
            fail(.unknownRelay)
        } catch {
            fail(.invalidCode(error))
        }
    }

    /// Back to the start; a claimed channel is deleted, so that the desktop hears of it.
    func cancel() async {
        running?.cancel()
        await running?.value
        await abandonClaim()
        step = .entering
    }

    func retry() {
        step = .entering
    }

    // MARK: - The flow

    private func start(_ code: PairingCode, at relay: RelayEndpoint) {
        guard running == nil else { return }
        step = .claiming
        running = Task {
            await run(code, at: relay)
            running = nil
        }
    }

    private func run(_ code: PairingCode, at relay: RelayEndpoint) async {
        let client = RelayClient(endpoint: relay, transport: transport)
        do {
            // Steps 15–16: fresh keys for every pairing.
            let keys: DeviceKeys
            do { keys = try keyStore.create() } catch { return fail(.keys) }
            let sign: @Sendable (Data) throws -> Data = { [keys] in try keys.sign($0) }

            // Steps 17–22.
            let pairing = try await client.lookUp(pairingId: code.pairingId)
            let transcript = PairingMAC.transcript(
                channelId: pairing.channelId, desktopKeys: pairing.desktopKeys, phoneKeys: keys.bundle)
            let session = try await client.claim(
                pairingId: code.pairingId, channelId: pairing.channelId, phoneKeys: keys.bundle,
                macP: PairingMAC.phone(code: code, transcript: transcript), sign: sign)
            claimed = (client, pairing.channelId, session.idToken)
            try Task.checkCancellation()

            // Steps 27–29: the words, while the desktop asks.
            step = .comparing(SafetyPhrase(desktopKeys: pairing.desktopKeys, phoneKeys: keys.bundle, wordList: wordList))

            // Steps 36–37.
            let macD = try await awaitPaired(client: client, channelId: pairing.channelId, idToken: session.idToken)
            guard let macD, PairingMAC.isValidDesktopMAC(macD, code: code, transcript: transcript) else {
                await abandonClaim()
                return fail(.notVerified)
            }
            let record = PairingRecord(relayHost: relay.host, channelId: pairing.channelId, desktopKeys: pairing.desktopKeys)
            do { try pairingStore.save(record) } catch {
                await abandonClaim()
                return fail(.keys)
            }
            claimed = nil
            step = .paired(record)
        } catch is CancellationError {
            return
        } catch RelayError.notFound {
            await dropKeys()
            fail(claimed == nil ? .expired : .notAllowed)
        } catch is ChannelGone {
            claimed = nil
            await dropKeys()
            fail(.notAllowed)
        } catch {
            await abandonClaim()
            fail(.unreachable)
        }
    }

    private struct ChannelGone: Error {}

    /// Follows `meta` with the claim's token until `status` is `paired` (§5.10).
    /// Returns its `macD`, nil when it came without one; throws `ChannelGone`
    /// when `meta` vanishes — denied, cancelled or run out at the desktop.
    private func awaitPaired(client: RelayClient, channelId: Data, idToken: String) async throws -> Data? {
        var failures = 0
        while failures < 3 {
            if failures > 0 { try await Task.sleep(for: .seconds(1)) }
            do {
                for try await event in try await client.openNode(channelId: channelId, node: "meta", idToken: idToken) {
                    switch event {
                    case .tree(.null), .cancelled:
                        throw ChannelGone()
                    case .tree(let meta):
                        failures = 0
                        if meta["status"]?.stringValue == "paired" {
                            return meta["macD"]?.stringValue.flatMap { Data(base64URL: $0) }
                        }
                    case .keepAlive, .authRevoked:
                        continue
                    }
                }
                failures += 1
            } catch let error as RelayError where error.isTransient {
                failures += 1
            }
        }
        throw RelayError.unreachable
    }

    private func abandonClaim() async {
        if let claimed {
            try? await claimed.client.deleteChannel(claimed.channelId, idToken: claimed.idToken)
        }
        claimed = nil
        await dropKeys()
    }

    /// Keys of a pairing that did not finish are of no use to the next one.
    private func dropKeys() async {
        try? keyStore.delete()
    }

    private func fail(_ failure: Failure) {
        step = .failed(failure)
    }
}
