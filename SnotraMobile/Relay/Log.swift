import Foundation
import os

extension Logger {
    /// Calls to the relay, App Check and App Attest that went wrong (#63).
    static let relay = Logger(subsystem: "dev.snotra-ai.mobile", category: "relay")
    /// The pairing's steps and how it ended.
    static let pairing = Logger(subsystem: "dev.snotra-ai.mobile", category: "pairing")
}

/// What may go into the log about a call: only causes — status, error kinds,
/// steps — never tokens, keys, codes or channel ids, so that all of it can be `.public`.
enum LogText {
    /// The host and the path with every segment that may carry an id — a pairing
    /// id, a channel id, an app id — left out: `pairings/…/claim`, `…/…:exchangeAppAttestAttestation`.
    static func path(of url: URL?) -> String {
        guard let url else { return "?" }
        let segments = url.pathComponents.dropFirst().map { segment -> String in
            if let colon = segment.lastIndex(of: ":") { return "…" + segment[colon...] }
            return segment.allSatisfy { ($0.isLetter && $0.isLowercase) || $0 == "." } ? segment : "…"
        }
        return (url.host() ?? "?") + "/" + segments.joined(separator: "/")
    }

    /// The case of the app's own errors, only the domain and code of anyone
    /// else's — whose text may carry what does not belong here.
    static func error(_ error: any Error) -> String {
        switch error {
        case let error as RelayError: "RelayError.\(error)"
        case let error as AppCheckError: "AppCheckError.\(error)"
        case let error as URLError: "URLError \(error.code.rawValue)"
        default: "\((error as NSError).domain) \((error as NSError).code)"
        }
    }
}
