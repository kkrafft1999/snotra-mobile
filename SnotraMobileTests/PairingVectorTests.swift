import CryptoKit
import Foundation
import Testing
@testable import SnotraMobile

/// Recomputes `pairing-v1.json` (remote protocol §9).
struct PairingVectorTests {
    let vectors: [String: Any]
    let desktopSign: P256.Signing.PrivateKey
    let phoneSign: P256.Signing.PrivateKey
    let desktopKeys: KeyBundle
    let phoneKeys: KeyBundle
    let channelId: Data
    let code: PairingCode

    init() throws {
        vectors = try ProtocolVectors.load("pairing-v1")
        let desktop = vectors[object: "desktop"], phone = vectors[object: "phone"]
        desktopSign = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: desktop[string: "signPrivate"]))
        phoneSign = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: phone[string: "signPrivate"]))
        let desktopAgree = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: desktop[string: "agreePrivate"]))
        let phoneAgree = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: phone[string: "agreePrivate"]))
        desktopKeys = KeyBundle(sign: desktopSign.publicKey, agree: desktopAgree.publicKey)
        phoneKeys = KeyBundle(sign: phoneSign.publicKey, agree: phoneAgree.publicKey)
        channelId = Data(b64u: vectors[string: "channelId"])
        let codeVector = vectors[object: "code"]
        code = PairingCode(pairingId: codeVector[string: "pairingId"], secret: codeVector[string: "secret"])
    }

    @Test func publicKeysAndBundlesMatch() throws {
        for (side, bundle) in [("desktop", desktopKeys), ("phone", phoneKeys)] {
            let vector = vectors[object: side]
            let keys = vector[object: "keys"]
            #expect(bundle.sign.base64URLEncodedString == keys[string: "sign"])
            #expect(bundle.agree.base64URLEncodedString == keys[string: "agree"])
            #expect(bundle.bytes.hexString == vector[string: "keyBundle"])
            let decoded = try JSONDecoder().decode(KeyBundle.self, from: JSONSerialization.data(withJSONObject: keys))
            #expect(decoded == bundle)
        }
    }

    @Test func codeIsBuiltAsTheDesktopBuildsIt() {
        let vector = vectors[object: "code"]
        #expect(code.check == vector[string: "check"])
        #expect(code.symbols == vector[string: "code"])
        #expect(code.display == vector[string: "display"])
        #expect(code.qrPayload(relayHost: "relay.example") == vector[string: "qr"])
        #expect(code.macKey.withUnsafeBytes { Data($0) }.hexString == vector[string: "macKey"])
        #expect(Self.value(of: code.pairingId) == UInt128(vector["pairingIdValue"] as! Int))
        #expect(Self.value(of: code.secret) == UInt128(String(vector[string: "secretValue"].dropFirst(2)), radix: 16))
    }

    @Test func typedKeysParseAsSpecified() {
        let cases = vectors["parse"] as! [[String: Any]]
        #expect(cases.count == 7)
        for parseCase in cases {
            let input = parseCase[string: "input"], expect = parseCase[object: "expect"]
            do {
                let parsed = try PairingCode.parse(typed: input)
                #expect(parsed.symbols == expect["code"] as? String, "\(input)")
            } catch {
                #expect(error.rawValue == expect["error"] as? String, "\(input)")
            }
        }
    }

    @Test func qrCodesNamingAnotherRelayAreRefused() throws {
        let qr = vectors[object: "code"][string: "qr"]
        let parsed = try PairingCode.parse(qr: qr, allowedHosts: ["relay.example"])
        #expect(parsed.relayHost == "relay.example" && parsed.code == code)
        #expect(throws: PairingCode.Failure.unknownRelay) {
            try PairingCode.parse(qr: qr, allowedHosts: ["relay.snotra.test"])
        }
        #expect(throws: PairingCode.Failure.unsupportedVersion) {
            try PairingCode.parse(qr: "snotra-pair:v2/relay.example/\(code.symbols)", allowedHosts: ["relay.example"])
        }
    }

    @Test func macsMatchAndDoNotPassForEachOther() {
        let transcript = PairingMAC.transcript(channelId: channelId, desktopKeys: desktopKeys, phoneKeys: phoneKeys)
        #expect(channelId.count == 16)
        #expect(transcript.hexString == vectors[string: "transcript"])
        let macP = PairingMAC.phone(code: code, transcript: transcript)
        let macD = Data(b64u: vectors[string: "macD"])
        #expect(macP.base64URLEncodedString == vectors[string: "macP"])
        #expect(PairingMAC.desktop(code: code, transcript: transcript) == macD)
        #expect(PairingMAC.isValidDesktopMAC(macD, code: code, transcript: transcript))
        #expect(!PairingMAC.isValidDesktopMAC(macP, code: code, transcript: transcript))
    }

    @Test func safetyPhraseMatches() throws {
        let vector = vectors[object: "phrase"]
        let list = try SafetyPhrase.WordList.bundled()
        #expect(list.words.count == vector["listSize"] as? Int)
        #expect(SafetyPhrase.WordList.checksum == vector[string: "listSha256"])
        let hash0 = SafetyPhrase.firstHash(desktopKeys: desktopKeys, phoneKeys: phoneKeys)
        #expect(hash0.hexString == vector[string: "hash0"])
        #expect(Array(SafetyPhrase.values(of: hash0).prefix(6)) == vector["values"] as? [Int])
        let phrase = SafetyPhrase(desktopKeys: desktopKeys, phoneKeys: phoneKeys, wordList: list)
        #expect(phrase.indices == vector["indices"] as? [Int])
        #expect(phrase.words == vector["words"] as? [String])
        #expect(phrase.shown == vector[string: "shown"])
    }

    @Test func proofMessagesMatchAndTheirSignaturesVerify() throws {
        let challenge = Data(b64u: vectors[string: "challenge"])
        let expected: [String: (Data, P256.Signing.PublicKey)] = [
            "pair-open": (PairingProof.pairOpenMessage(challenge: challenge, desktopKeys: desktopKeys), desktopSign.publicKey),
            "pair-claim": (PairingProof.pairClaimMessage(challenge: challenge, channelId: channelId, phoneKeys: phoneKeys), phoneSign.publicKey),
            "token-desktop": (PairingProof.tokenMessage(challenge: challenge, channelId: channelId, role: .desktop), desktopSign.publicKey),
            "token-phone": (PairingProof.tokenMessage(challenge: challenge, channelId: channelId, role: .phone), phoneSign.publicKey),
        ]
        let proofs = vectors["proofs"] as! [[String: Any]]
        #expect(proofs.count == expected.count)
        for proof in proofs {
            let (message, key) = try #require(expected[proof[string: "name"]])
            #expect(message.hexString == proof[string: "message"], "\(proof[string: "name"])")
            #expect(PairingProof.verify(Data(b64u: proof[string: "signature"]), of: message, by: key))
        }
    }

    @Test func aSignatureTheAppMakesVerifies() throws {
        let challenge = Data(b64u: vectors[string: "challenge"])
        let message = PairingProof.tokenMessage(challenge: challenge, channelId: channelId, role: .phone)
        let signature = try PairingProof.sign(message, with: phoneSign)
        #expect(signature.count == 64)
        #expect(PairingProof.verify(signature, of: message, by: try phoneKeys.signingKey))
        #expect(!PairingProof.verify(signature, of: message + Data([0]), by: try phoneKeys.signingKey))
        #expect(!PairingProof.verify(signature, of: message, by: try desktopKeys.signingKey))
    }

    /// Crockford base32, most significant symbol first.
    static func value(of symbols: String) -> UInt128 {
        symbols.reduce(0) { $0 * 32 + UInt128(PairingCode.alphabet.firstIndex(of: $1)!) }
    }
}
