import Foundation

/// What a call to the relay or its database can end in (remote protocol §5.1).
enum RelayError: Error, Equatable, Sendable {
    case invalidRequest
    case unauthorized
    case refused
    /// Unknown, expired or used — the relay gives one answer for all three.
    case notFound
    case busy
    case tooLarge
    case rateLimited
    case unavailable
    /// The relay answered something the protocol does not allow.
    case invalidResponse
    /// No answer at all: no network, the host down, a timeout.
    case unreachable

    /// The reason of an error body, or the status when the body names none.
    init(status: Int, reason: String?) {
        switch reason {
        case "invalid-request": self = .invalidRequest
        case "unauthorized": self = .unauthorized
        case "refused": self = .refused
        case "not-found": self = .notFound
        case "busy": self = .busy
        case "too-large": self = .tooLarge
        case "rate-limited": self = .rateLimited
        case "unavailable": self = .unavailable
        default:
            switch status {
            case 400: self = .invalidRequest
            // The database answers a rule that refuses with 401 "Permission denied".
            case 401: self = .unauthorized
            case 403: self = .refused
            case 404: self = .notFound
            case 409: self = .busy
            case 413: self = .tooLarge
            case 429: self = .rateLimited
            case 500...599: self = .unavailable
            default: self = .invalidResponse
            }
        }
    }

    /// Worth trying again later, as opposed to an answer that will not change.
    var isTransient: Bool {
        switch self {
        case .unreachable, .unavailable, .rateLimited: true
        default: false
        }
    }
}
