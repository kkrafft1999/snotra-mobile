import CryptoKit
import Foundation

/// The six words both sides show for the person at the desktop to compare (§7).
struct SafetyPhrase: Equatable, Sendable {
    static let wordCount = 6

    let indices: [Int]
    let words: [String]

    /// Lower case as published, joined by ` · `.
    var shown: String { words.joined(separator: " · ") }

    init(desktopKeys: KeyBundle, phoneKeys: KeyBundle, wordList: WordList) {
        indices = Self.indices(desktopKeys: desktopKeys, phoneKeys: phoneKeys, listSize: wordList.words.count)
        words = indices.map { wordList.words[$0] }
    }

    /// `H0 = SHA-256(lp(label) ‖ KB_D ‖ KB_P)`, `H(i+1) = SHA-256(H(i))`, read as
    /// 16-bit big-endian values; values at or above `floor(65536 / N) · N` are
    /// skipped, so that every word is equally likely.
    static func indices(desktopKeys: KeyBundle, phoneKeys: KeyBundle, listSize: Int) -> [Int] {
        let bound = (65536 / listSize) * listSize
        var hash = firstHash(desktopKeys: desktopKeys, phoneKeys: phoneKeys)
        var result: [Int] = []
        while true {
            for value in values(of: hash) where value < bound {
                result.append(value % listSize)
                if result.count == wordCount { return result }
            }
            hash = Data(SHA256.hash(data: hash))
        }
    }

    static func firstHash(desktopKeys: KeyBundle, phoneKeys: KeyBundle) -> Data {
        Data(SHA256.hash(data: ProtocolBytes.lp("snotra/v1 phrase") + desktopKeys.bytes + phoneKeys.bytes))
    }

    static func values(of hash: Data) -> [Int] {
        let bytes = Array(hash)
        return stride(from: 0, to: bytes.count, by: 2).map { Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]) }
    }

    /// The EFF short word list 2.0, part of protocol version 1. Bundled as
    /// `safety-words-v1.json`; its licence note sits next to it.
    struct WordList: Sendable {
        enum Failure: Error { case missing, wrongChecksum }

        /// SHA-256 of the words joined by `\n`, with a final `\n`.
        static let checksum = "7aa57a4d3ecf6581729992bad9575bacdebf7c28378af2aec6a50f11aec326f5"

        let words: [String]

        init(words: [String]) throws(Failure) {
            let joined = words.map { $0 + "\n" }.joined()
            guard Data(SHA256.hash(data: Data(joined.utf8))).hexString == Self.checksum else {
                throw .wrongChecksum
            }
            self.words = words
        }

        static func bundled(in bundle: Bundle = .main) throws -> WordList {
            guard let url = bundle.url(forResource: "safety-words-v1", withExtension: "json") else {
                throw Failure.missing
            }
            struct File: Decodable { let words: [String] }
            return try WordList(words: JSONDecoder().decode(File.self, from: Data(contentsOf: url)).words)
        }
    }
}
