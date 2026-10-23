import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

/// The relay named in the environment, if any.
enum LiveRelay {
    static var endpoint: RelayEndpoint? {
        let environment = ProcessInfo.processInfo.environment
        guard let relay = environment["SNOTRA_RELAY_URL"].flatMap(URL.init(string:)),
              let database = environment["SNOTRA_RELAY_DATABASE_URL"].flatMap(URL.init(string:)),
              let identity = environment["SNOTRA_RELAY_IDENTITY_TOOLKIT_URL"].flatMap(URL.init(string:)),
              let apiKey = environment["SNOTRA_RELAY_API_KEY"],
              let appCheck = environment["SNOTRA_RELAY_APP_CHECK_TOKEN"]
        else { return nil }
        let host = [relay.host(), relay.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        return RelayEndpoint(host: host, relayURL: relay, databaseURL: database, identityToolkitURL: identity,
                             apiKey: apiKey, appCheckToken: appCheck)
    }
}

/// The channel against a real relay — the emulator, or Snotra's stand-in
/// (`e2e/remote/relay-stand-in.js`). Off unless the relay is named in the
/// environment (`TEST_RUNNER_SNOTRA_RELAY_URL` and the others of `LiveRelay`, as
/// `xcodebuild test` passes them on); CI does not run it.
///
/// The test plays the desktop itself, step by step over the endpoints, so that
/// the phone's side meets a paired channel the relay set up.
@Suite(.enabled(if: LiveRelay.endpoint != nil))
struct RelayLiveTests {
    let endpoint = LiveRelay.endpoint!
    let transport = URLSessionTransport()
    var client: RelayClient { RelayClient(endpoint: endpoint, transport: transport) }

    let desktopSign = P256.Signing.PrivateKey(), desktopAgree = P256.KeyAgreement.PrivateKey()
    let phoneSign = P256.Signing.PrivateKey(), phoneAgree = P256.KeyAgreement.PrivateKey()

    @Test func aPairedPhoneConnectsSeesTheDesktopAndHearsTheChannelEnd() async throws {
        let (channelId, desktopToken) = try await pair()

        // The desktop's heartbeat (§12 step 3).
        try await put(channelId: channelId, node: "presence/desktop", token: desktopToken,
                      body: .object(["lastSeen": .serverTimestamp]))

        let channel = RelayChannel(client: client, channelId: channelId) { [phoneSign] message in
            try phoneSign.signature(for: message).rawRepresentation
        }
        let log = EventLog(channel)
        await channel.start()
        #expect(await log.waitFor(.connected(desktopOnline: true), within: 10))
        #expect(await log.waitFor(within: 10) { $0 == .inbox(.null) })

        // *Remove phone* at the desktop (§5.8): the phone's `meta` vanishes.
        _ = try await post("channels/\(channelId.base64URLEncodedString)", method: "DELETE", body: nil, bearer: desktopToken)
        #expect(await log.waitFor(.ended, within: 10))
    }

    /// The app's whole pairing (#34) — look-up, claim, the words, `MAC_D` — with the desktop played here.
    @MainActor @Test func theAppPairsThroughTheRelay() async throws {
        let desktopKeys = KeyBundle(sign: desktopSign.publicKey, agree: desktopAgree.publicKey)
        let (channelId, pairingId, desktopToken) = try await openPairing()
        let secret = String((0..<15).map { _ in PairingCode.alphabet.randomElement()! })
        let code = PairingCode(pairingId: pairingId, secret: secret)
        let pairingMemory = MemoryStore()
        let flow = PairingFlow(
            relays: [endpoint], transport: transport,
            keyStore: DeviceKeyStore(store: MemoryStore(), kind: .software),
            pairingStore: PairingStore(store: pairingMemory), wordList: try .bundled())
        flow.submit(typed: code.display)

        // The desktop sees the claim (steps 25–26) and checks MAC_P.
        var meta = JSONValue.null
        for _ in 0..<100 where meta["status"]?.stringValue != "pending" {
            try await Task.sleep(for: .milliseconds(100))
            meta = try await get(channelId: channelId, node: "meta", token: desktopToken)
        }
        let phoneKeys = try KeyBundle(json: try #require(meta["phoneKeys"]))
        let transcript = PairingMAC.transcript(channelId: channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys)
        #expect(meta["macP"]?.stringValue == PairingMAC.phone(code: code, transcript: transcript).base64URLEncodedString)
        guard case .comparing = flow.step else { Issue.record("no words shown: \(flow.step)"); return }

        // *Allow* (steps 33–35).
        _ = try await post("channels/\(channelId.base64URLEncodedString)/confirm", body: .object([
            "macD": .string(PairingMAC.desktop(code: code, transcript: transcript).base64URLEncodedString),
        ]), bearer: desktopToken)
        for _ in 0..<100 where !isPaired(flow.step) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(flow.step == .paired(PairingRecord(relayHost: endpoint.host, channelId: channelId, desktopKeys: desktopKeys)))
        #expect(try PairingStore(store: pairingMemory).load()?.channelId == channelId)

        _ = try await post("channels/\(channelId.base64URLEncodedString)", method: "DELETE", body: nil, bearer: desktopToken)
    }

    /// #35: *Disconnect* in the app, and the desktop sees its channel gone.
    @MainActor @Test func disconnectingInTheAppEndsTheChannelForTheDesktop() async throws {
        let (channelId, desktopToken) = try await pair()
        let model = pairedModel(channelId: channelId)
        model.activate()
        for _ in 0..<100 where model.connection != .connected(desktopOnline: false) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.connection == .connected(desktopOnline: false))
        await model.unpair()
        #expect(model.pairing == nil)
        #expect(try await get(channelId: channelId, node: "meta", token: desktopToken) == .null)
    }

    /// #35: *Remove phone* at the desktop, and the app notices.
    @MainActor @Test func removingAtTheDesktopEndsThePairingInTheApp() async throws {
        let (channelId, desktopToken) = try await pair()
        let model = pairedModel(channelId: channelId)
        model.activate()
        for _ in 0..<100 where model.connection != .connected(desktopOnline: false) { try await Task.sleep(for: .milliseconds(100)) }
        _ = try await post("channels/\(channelId.base64URLEncodedString)", method: "DELETE", body: nil, bearer: desktopToken)
        for _ in 0..<100 where model.notice == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.notice == .removedAtDesktop)
        #expect(model.pairing == nil)
    }

    /// An app that holds the keys `pair()` claimed with.
    @MainActor private func pairedModel(channelId: Data) -> RemoteModel {
        let keys = MemoryStore()
        keys.items[DeviceKeyStore.signAccount] = phoneSign.rawRepresentation
        keys.items[DeviceKeyStore.agreeAccount] = phoneAgree.rawRepresentation
        let pairings = MemoryStore()
        try? PairingStore(store: pairings).save(PairingRecord(
            relayHost: endpoint.host, channelId: channelId,
            desktopKeys: KeyBundle(sign: desktopSign.publicKey, agree: desktopAgree.publicKey)))
        let model = RemoteModel(relays: [endpoint], transport: transport,
                                keyStore: DeviceKeyStore(store: keys, kind: .software),
                                pairingStore: PairingStore(store: pairings))
        model.reload()
        return model
    }

    private func isPaired(_ step: PairingFlow.Step) -> Bool {
        if case .paired = step { true } else { false }
    }

    /// §5.3, as the desktop does it.
    private func openPairing() async throws -> (channelId: Data, pairingId: String, desktopToken: String) {
        let desktopKeys = KeyBundle(sign: desktopSign.publicKey, agree: desktopAgree.publicKey)
        let challenge = try await client.challenge()
        let opened = try await post("pairings", body: .object([
            "challenge": .string(challenge.text),
            "desktopKeys": try keys(desktopKeys),
            "proof": .string(try desktopSign.signature(for: PairingProof.pairOpenMessage(
                challenge: challenge.bytes, desktopKeys: desktopKeys)).rawRepresentation.base64URLEncodedString),
        ]))
        let channelId = try #require(opened["channelId"]?.stringValue.flatMap { Data(base64URL: $0) })
        let pairingId = try #require(opened["pairingId"]?.stringValue)
        let desktop = try await client.signIn(customToken: try #require(opened["token"]?.stringValue))
        return (channelId, pairingId, desktop.idToken)
    }

    /// Part 1 with both sides played here: open (§5.3), claim (§5.5), confirm (§5.6).
    private func pair() async throws -> (channelId: Data, desktopToken: String) {
        let (channelId, pairingId, desktopToken) = try await openPairing()
        let phoneKeys = KeyBundle(sign: phoneSign.publicKey, agree: phoneAgree.publicKey)
        let challenge = try await client.challenge()
        _ = try await post("pairings/\(pairingId)/claim", body: .object([
            "challenge": .string(challenge.text),
            "phoneKeys": try keys(phoneKeys),
            // The relay cannot check MAC_P; any 32 bytes do here.
            "macP": .string(Data(repeating: 1, count: 32).base64URLEncodedString),
            "proof": .string(try phoneSign.signature(for: PairingProof.pairClaimMessage(
                challenge: challenge.bytes, channelId: channelId, phoneKeys: phoneKeys)).rawRepresentation.base64URLEncodedString),
        ]))
        _ = try await post("channels/\(channelId.base64URLEncodedString)/confirm",
                           body: .object(["macD": .string(Data(repeating: 2, count: 32).base64URLEncodedString)]),
                           bearer: desktopToken)
        return (channelId, desktopToken)
    }

    private func keys(_ bundle: KeyBundle) throws -> JSONValue {
        try JSONValue(data: JSONEncoder().encode(bundle))
    }

    private func post(_ path: String, method: String = "POST", body: JSONValue?, bearer: String? = nil) async throws -> JSONValue {
        var request = URLRequest(url: endpoint.relayURL.appending(path: path))
        request.httpMethod = method
        request.setValue(endpoint.appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.data()
        }
        let (data, response) = try await transport.send(request)
        try #require((200..<300).contains(response.statusCode), "\(method) \(path): \(response.statusCode) \(String(decoding: data, as: UTF8.self))")
        return data.isEmpty ? .null : try JSONValue(data: data)
    }

    private func get(channelId: Data, node: String, token: String) async throws -> JSONValue {
        let request = URLRequest(url: endpoint.databaseNodeURL(channelId: channelId, node: node, idToken: token))
        let (data, response) = try await transport.send(request)
        try #require(response.statusCode == 200, "GET \(node): \(response.statusCode)")
        return try JSONValue(data: data)
    }

    private func put(channelId: Data, node: String, token: String, body: JSONValue) async throws {
        var request = URLRequest(url: endpoint.databaseNodeURL(channelId: channelId, node: node, idToken: token, silent: true))
        request.httpMethod = "PUT"
        request.httpBody = try body.data()
        let (_, response) = try await transport.send(request)
        try #require((200..<300).contains(response.statusCode), "PUT \(node): \(response.statusCode)")
    }
}
