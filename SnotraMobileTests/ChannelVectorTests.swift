import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

/// Recomputes `channel-v1.json` (remote protocol §18).
struct ChannelVectorTests {
    let vectors: [String: Any]
    let channelId: Data
    let desktopAgree: P256.KeyAgreement.PrivateKey
    let phoneAgree: P256.KeyAgreement.PrivateKey
    let desktopKeys: KeyBundle
    let phoneKeys: KeyBundle
    let desktopEphemeral: Curve25519.KeyAgreement.PrivateKey
    let phoneEphemeral: Curve25519.KeyAgreement.PrivateKey

    init() throws {
        vectors = try ProtocolVectors.load("channel-v1")
        let pairing = try ProtocolVectors.load("pairing-v1")
        channelId = Data(b64u: pairing[string: "channelId"])
        let desktop = pairing[object: "desktop"], phone = pairing[object: "phone"]
        desktopAgree = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: desktop[string: "agreePrivate"]))
        phoneAgree = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: phone[string: "agreePrivate"]))
        desktopKeys = try JSONDecoder().decode(KeyBundle.self, from: JSONSerialization.data(withJSONObject: desktop[object: "keys"]))
        phoneKeys = try JSONDecoder().decode(KeyBundle.self, from: JSONSerialization.data(withJSONObject: phone[object: "keys"]))
        let ephemeral = vectors[object: "ephemeral"]
        desktopEphemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: ephemeral[object: "desktop"][string: "private"]))
        phoneEphemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: ephemeral[object: "phone"][string: "private"]))
    }

    var sessionKeys: SessionKeys {
        get throws {
            let ss = try SessionKeys.rawBytes(of: phoneAgree.sharedSecretFromKeyAgreement(with: desktopKeys.agreementKey))
            let ee = try SessionKeys.rawBytes(of: phoneEphemeral.sharedSecretFromKeyAgreement(with: desktopEphemeral.publicKey))
            return SessionKeys(staticShared: ss, ephemeralShared: ee, transcriptHash: transcriptHash)
        }
    }

    var transcriptHash: Data {
        Handshake.transcriptHash(
            channelId: channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys,
            offered: [1], phoneEphemeral: phoneEphemeral.publicKey.rawRepresentation,
            chosen: 1, desktopEphemeral: desktopEphemeral.publicKey.rawRepresentation
        )
    }

    @Test func handshakeRecordsMatch() throws {
        let ephemeral = vectors[object: "ephemeral"]
        #expect(desktopEphemeral.publicKey.rawRepresentation.base64URLEncodedString == ephemeral[object: "desktop"][string: "public"])
        #expect(phoneEphemeral.publicKey.rawRepresentation.base64URLEncodedString == ephemeral[object: "phone"][string: "public"])

        let one = vectors[object: "handshake1"]
        #expect(one[string: "path"] == "/channels/\(channelId.base64URLEncodedString)/handshake/phone")
        let offer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Handshake.Offer(ephemeral: phoneEphemeral.publicKey)))
        #expect(NSDictionary(dictionary: offer as! [String: Any]) == NSDictionary(dictionary: one[object: "record"]))

        let two = vectors[object: "handshake2"]
        #expect(two[string: "path"] == "/channels/\(channelId.base64URLEncodedString)/handshake/desktop")
        let answer = try Handshake.decodeAnswer(JSONSerialization.data(withJSONObject: two[object: "record"]))
        #expect(answer == .accepted(version: 1, ephemeral: desktopEphemeral.publicKey.rawRepresentation))
        #expect(Handshake.chosenVersion(offered: [1]) == 1)
    }

    @Test func aVersionNobodySharesIsRefused() throws {
        let mismatch = vectors[object: "versionMismatch"]
        #expect(Handshake.chosenVersion(offered: (mismatch["offered"] as! [Int]).map(UInt8.init)) == nil)
        let answer = try Handshake.decodeAnswer(JSONSerialization.data(withJSONObject: mismatch[object: "answer"]))
        #expect(answer == .unsupported(desktopVersions: [1]))
    }

    @Test func sharedSecretsAndSessionKeysMatch() throws {
        let phoneSide = try SessionKeys.rawBytes(of: phoneAgree.sharedSecretFromKeyAgreement(with: desktopKeys.agreementKey))
        let desktopSide = try SessionKeys.rawBytes(of: desktopAgree.sharedSecretFromKeyAgreement(with: phoneKeys.agreementKey))
        #expect(phoneSide.hexString == vectors[string: "staticShared"])
        #expect(desktopSide == phoneSide)
        let ee = try SessionKeys.rawBytes(of: phoneEphemeral.sharedSecretFromKeyAgreement(with: desktopEphemeral.publicKey))
        #expect(ee.hexString == vectors[string: "ephemeralShared"])
        #expect(transcriptHash.hexString == vectors[string: "transcriptHash"])

        let keys = try sessionKeys
        #expect(keys.sidHex == vectors[string: "sid"])
        #expect(keys.toDesktop.withUnsafeBytes { Data($0) }.hexString == vectors[object: "keys"][string: "toDesktop"])
        #expect(keys.toPhone.withUnsafeBytes { Data($0) }.hexString == vectors[object: "keys"][string: "toPhone"])
    }

    @Test func envelopesSealAndOpenAsSpecified() throws {
        let keys = try sessionKeys
        for envelope in vectors["envelopes"] as! [[String: Any]] {
            let direction = try #require(Envelope.Direction(rawValue: envelope[string: "direction"]))
            let counter = UInt64(envelope["counter"] as! Int)
            let plaintext = Data(envelope[string: "plaintext"].utf8)
            let sealed = Data(b64u: envelope[object: "record"][string: "c"])
            #expect(Envelope.path(channelId: channelId, direction: direction, sid: keys.sid, counter: counter) == envelope[string: "path"])
            #expect(Envelope.nonce(counter: counter).hexString == envelope[string: "nonce"])
            #expect(Envelope.associatedData(sid: keys.sid, direction: direction, counter: counter).hexString == envelope[string: "aad"])
            #expect(try Envelope.seal(plaintext, keys: keys, direction: direction, counter: counter) == sealed)
            #expect(try Envelope.open(sealed, keys: keys, direction: direction, counter: counter) == plaintext)
        }
    }

    @Test func aTamperedEnvelopeDoesNotOpen() throws {
        let tampered = vectors[object: "tampered"]
        #expect(tampered[string: "expect"] == "reject")
        let sealed = Data(b64u: tampered[object: "record"][string: "c"])
        #expect(throws: Envelope.Failure.doesNotOpen) {
            try Envelope.open(sealed, keys: try sessionKeys, direction: .toDesktop, counter: 0)
        }
    }

    @Test func envelopesOpenOnlyUnderTheirOwnCounterAndDirection() throws {
        let keys = try sessionKeys
        let sealed = try Envelope.seal(Data("{}".utf8), keys: keys, direction: .toPhone, counter: 7)
        #expect(throws: Envelope.Failure.doesNotOpen) { try Envelope.open(sealed, keys: keys, direction: .toPhone, counter: 8) }
        #expect(throws: Envelope.Failure.doesNotOpen) { try Envelope.open(sealed, keys: keys, direction: .toDesktop, counter: 7) }
    }

    @Test func theOrderRuleActsAsSpecified() {
        let order = vectors[object: "order"]
        #expect(order["holdWindow"] as? Int == Int(ReceiveWindow<Int>.holdWindow))
        var window = ReceiveWindow<Int>()
        let arrivals = order["arrivals"] as! [Int]
        let actions = order["actions"] as! [[String: Any]]
        for (arrival, expected) in zip(arrivals, actions) {
            #expect(expected["counter"] as? Int == arrival)
            switch window.receive(counter: UInt64(arrival), message: arrival) {
            case .deliver(let delivered):
                #expect(expected[string: "action"] == "deliver")
                #expect(delivered.map { Int($0.counter) } == expected["delivered"] as? [Int])
            case .hold: #expect(expected[string: "action"] == "hold")
            case .drop: #expect(expected[string: "action"] == "drop")
            case .startOver: #expect(expected[string: "action"] == "rehandshake")
            }
        }
    }
}
