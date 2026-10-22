import Foundation

/// A node of the Realtime Database's tree, as its REST interface sends it.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(data: Data) throws {
        self.init(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any value: Any) {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let list as [Any]: self = .array(list.map(JSONValue.init(any:)))
        case let map as [String: Any]: self = .object(map.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let list): list.map(\.any)
        case .object(let map): map.mapValues(\.any)
        }
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys])
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let map) = self { map[key] } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    /// The database's placeholder for its own clock, `{".sv": "timestamp"}`.
    static let serverTimestamp = JSONValue.object([".sv": .string("timestamp")])

    /// A `put` (replace) or `patch` (merge the children) at a path of the
    /// streaming interface. Empty objects and nulls vanish, as in the database.
    func applying(_ data: JSONValue, at path: String, merge: Bool) -> JSONValue {
        applying(data, at: path.split(separator: "/").map(String.init)[...], merge: merge)
    }

    private func applying(_ data: JSONValue, at path: ArraySlice<String>, merge: Bool) -> JSONValue {
        guard let head = path.first else {
            guard merge, case .object(let children) = data else { return data.pruned }
            var result = self
            for (key, child) in children { result = result.applying(child, at: [key][...], merge: false) }
            return result
        }
        var map: [String: JSONValue] = if case .object(let existing) = self { existing } else { [:] }
        let child = (map[head] ?? .null).applying(data, at: path.dropFirst(), merge: merge)
        map[head] = child == .null ? nil : child
        return map.isEmpty ? .null : .object(map)
    }

    private var pruned: JSONValue {
        guard case .object(let map) = self else { return self }
        let kept = map.mapValues(\.pruned).filter { $0.value != .null }
        return kept.isEmpty ? .null : .object(kept)
    }
}
