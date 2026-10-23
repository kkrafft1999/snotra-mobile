import Foundation

/// The phone's half of part 1 (remote protocol §5.4, §5.5, §5.8).
extension RelayClient {
    /// What the relay holds for a pairing: the channel and the desktop's keys (§5.4).
    struct Pairing: Equatable, Sendable {
        let channelId: Data
        let desktopKeys: KeyBundle
        let expiresAt: Date
    }

    /// §5.4, with a reusable App Check token. `.notFound` for an unknown, expired or claimed pairing.
    func lookUp(pairingId: String) async throws -> Pairing {
        let (answer, _) = try await call(endpoint.relayURL.appending(path: "pairings/\(pairingId)"), method: "GET", body: nil,
                                   appCheck: .reusable)
        guard let channelId = answer["channelId"]?.stringValue.flatMap({ Data(base64URL: $0) }), channelId.count == 16,
              let keys = answer["desktopKeys"], let desktopKeys = try? KeyBundle(json: keys),
              let expiresAt = answer["expiresAt"]?.numberValue
        else { throw RelayError.invalidResponse }
        return Pairing(channelId: channelId, desktopKeys: desktopKeys,
                       expiresAt: Date(timeIntervalSince1970: expiresAt / 1000))
    }

    /// §5.5: the phone's keys and `MAC_P` into the channel; the answer's token
    /// lets the phone follow `meta` until the desktop confirms. The relay
    /// consumes the App Check token, so it is a limited-use one.
    func claim(pairingId: String, channelId: Data, phoneKeys: KeyBundle, macP: Data,
               sign: @Sendable (Data) throws -> Data) async throws -> Session {
        let challenge = try await challenge()
        let proof = try sign(PairingProof.pairClaimMessage(challenge: challenge.bytes, channelId: channelId, phoneKeys: phoneKeys))
        let (answer, serverDate) = try await call(endpoint.relayURL.appending(path: "pairings/\(pairingId)/claim"), body: .object([
            "challenge": .string(challenge.text),
            "phoneKeys": try phoneKeys.json,
            "macP": .string(macP.base64URLEncodedString),
            "proof": .string(proof.base64URLEncodedString),
        ]), appCheck: .limitedUse)
        guard answer["channelId"]?.stringValue == channelId.base64URLEncodedString,
              let token = answer["token"]?.stringValue
        else { throw RelayError.invalidResponse }
        return try await signIn(customToken: token, serverDate: serverDate)
    }

    /// §5.8: the channel with everything under it, for a wrong `MAC_D` or a
    /// pairing the person stops on the phone.
    func deleteChannel(_ channelId: Data, idToken: String) async throws {
        _ = try await call(endpoint.relayURL.appending(path: "channels/\(channelId.base64URLEncodedString)"),
                           method: "DELETE", body: nil, bearer: idToken)
    }
}

extension KeyBundle {
    init(json: JSONValue) throws {
        self = try JSONDecoder().decode(KeyBundle.self, from: json.data())
    }

    var json: JSONValue {
        get throws { try JSONValue(data: JSONEncoder().encode(self)) }
    }
}
