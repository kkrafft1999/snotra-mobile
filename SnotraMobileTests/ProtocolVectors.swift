import Foundation
@testable import SnotraMobile

/// Loads the pinned test vectors from the test bundle (see `Vectors/README.md`).
enum ProtocolVectors {
    private final class BundleToken {}

    static func load(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}

extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    init(b64u: String) {
        self = Data(base64URL: b64u)!
    }
}

extension Dictionary where Key == String, Value == Any {
    subscript(object key: String) -> [String: Any] { self[key] as! [String: Any] }
    subscript(string key: String) -> String { self[key] as! String }
}
