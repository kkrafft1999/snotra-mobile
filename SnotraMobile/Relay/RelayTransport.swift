import Foundation

/// The network under the relay client, so that its logic runs in tests without one.
protocol RelayTransport: Sendable {
    /// One request with a small answer.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// A streaming request: the status first, then the body byte by byte.
    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, any Error>)
}

/// URLSession without a cache and without cookies: nothing of the relay's
/// answers is kept on the phone (concept §8).
struct URLSessionTransport: RelayTransport {
    static let requestTimeout: TimeInterval = 15

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw RelayError.invalidResponse }
        return (data, http)
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, any Error>) {
        var request = request
        // A stream sits quiet between the database's keep-alives; the request timeout would cut it.
        request.timeoutInterval = 24 * 60 * 60
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw RelayError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw RelayError.invalidResponse }
        let body = AsyncThrowingStream<UInt8, any Error> { continuation in
            let task = Task {
                do {
                    for try await byte in bytes { continuation.yield(byte) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RelayError.unreachable)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, body)
    }
}
