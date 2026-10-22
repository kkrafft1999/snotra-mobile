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
        return RelayEndpoint(relayURL: relay, databaseURL: database, identityToolkitURL: identity,
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

    /// Part 1 with both sides played here: open (§5.3), claim (§5.5), confirm (§5.6).
    private func pair() async throws -> (channelId: Data, desktopToken: String) {
        let desktopKeys = KeyBundle(sign: desktopSign.publicKey, agree: desktopAgree.publicKey)
        var challenge = try await client.challenge()
        let opened = try await post("pairings", body: .object([
            "challenge": .string(challenge.text),
            "desktopKeys": try keys(desktopKeys),
            "proof": .string(try desktopSign.signature(for: PairingProof.pairOpenMessage(
                challenge: challenge.bytes, desktopKeys: desktopKeys)).rawRepresentation.base64URLEncodedString),
        ]))
        let channelId = try #require(opened["channelId"]?.stringValue.flatMap { Data(base64URL: $0) })
        let pairingId = try #require(opened["pairingId"]?.stringValue)
        let desktop = try await client.signIn(customToken: try #require(opened["token"]?.stringValue))

        let phoneKeys = KeyBundle(sign: phoneSign.publicKey, agree: phoneAgree.publicKey)
        challenge = try await client.challenge()
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
                           bearer: desktop.idToken)
        return (channelId, desktop.idToken)
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

    private func put(channelId: Data, node: String, token: String, body: JSONValue) async throws {
        var request = URLRequest(url: endpoint.databaseNodeURL(channelId: channelId, node: node, idToken: token, silent: true))
        request.httpMethod = "PUT"
        request.httpBody = try body.data()
        let (_, response) = try await transport.send(request)
        try #require((200..<300).contains(response.statusCode), "PUT \(node): \(response.statusCode)")
    }
}
