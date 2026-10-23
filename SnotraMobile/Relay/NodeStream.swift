import Foundation

/// What one streamed node of the database says (spec §12 step 2).
enum NodeEvent: Equatable, Sendable {
    /// The node's whole tree after a `put` or `patch`, `.null` when it is gone.
    case tree(JSONValue)
    case keepAlive
    /// The rules took the read away: the channel went, or its status changed.
    case cancelled
    /// The ID token ran out or was revoked; renew it and open the node again.
    case authRevoked
}

extension RelayClient {
    /// Opens one node of a channel by REST streaming. Throws for an answer that
    /// is not a stream (`.unauthorized` for a refused token); the events end
    /// when the database closes the stream, and with an error when it breaks.
    func openNode(channelId: Data, node: String, idToken: String,
                  maxEventBytes: Int = EventStreamParser.defaultMaxEventBytes)
        async throws -> AsyncThrowingStream<NodeEvent, any Error> {
        var request = URLRequest(url: endpoint.databaseNodeURL(channelId: channelId, node: node, idToken: idToken))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (response, body) = try await transport.stream(request)
        guard response.statusCode == 200 else { throw RelayError(status: response.statusCode, reason: nil) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = EventStreamParser(maxEventBytes: maxEventBytes)
                var tree = JSONValue.null
                do {
                    for try await byte in body {
                        guard let event = try parser.feed(byte) else { continue }
                        switch event.type {
                        case "put", "patch":
                            guard let change = try? JSONValue(data: Data(event.data.utf8)),
                                  let path = change["path"]?.stringValue
                            // An event that is no JSON changes nothing; the next full put repairs the copy.
                            else { continue }
                            tree = tree.applying(change["data"] ?? .null, at: path, merge: event.type == "patch")
                            continuation.yield(.tree(tree))
                        case "keep-alive": continuation.yield(.keepAlive)
                        case "cancel": continuation.yield(.cancelled)
                        case "auth_revoked": continuation.yield(.authRevoked)
                        default: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
