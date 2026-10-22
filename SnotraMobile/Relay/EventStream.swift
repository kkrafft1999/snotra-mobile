import Foundation

/// Server-sent events from a byte stream, as the Realtime Database's REST
/// streaming sends them: `event:` and `data:` lines, a blank line ends an
/// event, `:` starts a comment. Only what the phone needs of the format, as
/// the desktop's `event-stream.js` — no `id:` or `retry:`.
struct EventStreamParser {
    struct Event: Equatable, Sendable {
        let type: String
        let data: String
    }

    enum Failure: Error, Equatable {
        /// A relay must not be able to fill the phone's memory with one event.
        case eventTooLarge
    }

    static let defaultMaxEventBytes = 64 * 1024

    private let maxEventBytes: Int
    private var line: [UInt8] = []
    private var type = ""
    private var data: [String] = []
    private var size = 0
    private var lastWasCR = false

    init(maxEventBytes: Int = defaultMaxEventBytes) {
        self.maxEventBytes = maxEventBytes
    }

    /// Takes one byte; returns the event it completes, if any.
    mutating func feed(_ byte: UInt8) throws(Failure) -> Event? {
        switch byte {
        case 0x0A where lastWasCR:
            // The LF of a CRLF: the CR already ended the line.
            lastWasCR = false
            return nil
        case 0x0A, 0x0D:
            lastWasCR = byte == 0x0D
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return try take(text)
        default:
            lastWasCR = false
            line.append(byte)
            if line.count > maxEventBytes { throw .eventTooLarge }
            return nil
        }
    }

    private mutating func take(_ text: String) throws(Failure) -> Event? {
        if text.isEmpty {
            defer { type = ""; data = []; size = 0 }
            return data.isEmpty ? nil : Event(type: type.isEmpty ? "message" : type, data: data.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            let rest = text[text.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            (field, value) = (text[...], "")
        }
        size += value.utf8.count
        if size > maxEventBytes { throw .eventTooLarge }
        if field == "event" { type = String(value) } else if field == "data" { data.append(String(value)) }
        return nil
    }
}
