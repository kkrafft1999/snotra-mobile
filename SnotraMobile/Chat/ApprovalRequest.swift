import Foundation

/// A tool approval card as the desktop shows it to the phone
/// (remote-interface.md §8.1 `ApprovalRequest`): what the tool wants to do,
/// worded by the desktop, and the answers the phone may give — never more than
/// *allow once* and *deny* (§7.4, concept R5).
struct ApprovalRequest: Decodable, Identifiable, Equatable, Sendable {
    enum Answer: String, Sendable {
        case allowOnce = "allow-once"
        case deny
    }

    struct Target: Decodable, Equatable, Sendable {
        /// Relative inside the workspace, a place outside it as the card names it.
        let path: String
        let sensitive: Bool

        init(path: String, sensitive: Bool = false) {
            self.path = path
            self.sensitive = sensitive
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            sensitive = (try? container.decodeIfPresent(Bool.self, forKey: .sensitive)) ?? false
        }

        private enum CodingKeys: String, CodingKey { case path, sensitive }
    }

    /// What the tool would run or write, masked as on the desktop.
    struct Preview: Decodable, Equatable, Sendable {
        let text: String
        let truncated: Bool

        init(text: String, truncated: Bool = false) {
            self.text = text
            self.truncated = truncated
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        }

        private enum CodingKeys: String, CodingKey { case text, truncated }
    }

    /// A sandbox card: a place a command wants to reach, with the scopes the
    /// desktop offers for it, narrowest first.
    struct SandboxEntry: Decodable, Equatable, Sendable {
        let target: String
        let allow: [String]
    }

    let requestId: String
    let chatId: String
    let tool: String
    let targets: [Target]
    /// Worded in the connection's language.
    let reason: String
    /// `tool`, `sandbox` or `config`.
    let checkpoint: String
    let preview: Preview?
    let sandbox: [SandboxEntry]
    /// The answers this connection may give.
    let options: [String]

    var id: String { requestId }

    func offers(_ answer: Answer) -> Bool { options.contains(answer.rawValue) }

    /// What *allow once* grants on a sandbox card, named as the card showed it:
    /// the first scope of every place, as the desktop's own card does unless
    /// another is picked.
    var sandboxPaths: [String]? {
        sandbox.isEmpty ? nil : sandbox.map { $0.allow.first ?? $0.target }
    }

    init(requestId: String, chatId: String, tool: String, targets: [Target] = [], reason: String = "",
         checkpoint: String = "tool", preview: Preview? = nil, sandbox: [SandboxEntry] = [],
         options: [String] = [Answer.allowOnce.rawValue, Answer.deny.rawValue]) {
        self.requestId = requestId
        self.chatId = chatId
        self.tool = tool
        self.targets = targets
        self.reason = reason
        self.checkpoint = checkpoint
        self.preview = preview
        self.sandbox = sandbox
        self.options = options
    }

    init(from decoder: any Decoder) throws {
        struct Sandbox: Decodable { let entries: [SandboxEntry] }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        chatId = try container.decodeIfPresent(String.self, forKey: .chatId) ?? ""
        tool = try container.decodeIfPresent(String.self, forKey: .tool) ?? ""
        targets = (try? container.decodeIfPresent([Target].self, forKey: .targets)) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        checkpoint = (try? container.decodeIfPresent(String.self, forKey: .checkpoint)) ?? "tool"
        preview = try? container.decodeIfPresent(Preview.self, forKey: .preview)
        sandbox = (try? container.decodeIfPresent(Sandbox.self, forKey: .sandbox))?.entries ?? []
        options = (try? container.decodeIfPresent([String].self, forKey: .options)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case requestId, chatId, tool, targets, reason, checkpoint, preview, sandbox, options }
}

/// How a card was settled (`approval.resolved`), shown as a note where the card stood.
struct ApprovalOutcome: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case allowed
        case denied
        /// No answer came in time, or the run went on without one (`invalidated`).
        case expired
        /// Gone from the desktop while the phone was not listening; how is not known.
        case closed
    }

    enum Who: Equatable, Sendable {
        case thisPhone
        case desktop
        /// Another remote front end, by its client name.
        case other(String)
    }

    let kind: Kind
    let by: Who?

    init(kind: Kind, by: Who?) {
        self.kind = kind
        self.by = by
    }

    /// `approval.resolved`'s params. The relay carries one phone, so an answer
    /// of kind `relay` is this phone's own.
    init(resolved params: JSONValue) {
        let response = params["response"]?.stringValue
        kind = params["invalidated"] == .bool(true) || response == nil ? .expired
            : response == ApprovalRequest.Answer.deny.rawValue ? .denied : .allowed
        switch params["by"]?["kind"]?.stringValue {
        case "desktop": by = .desktop
        case "relay": by = .thisPhone
        case .some(let kind): by = .other(params["by"]?["client"]?.stringValue ?? kind)
        case nil: by = nil
        }
    }
}

/// A card in the chat: open and waiting for an answer, or settled and kept as a note.
struct ApprovalCard: Identifiable, Equatable, Sendable {
    let request: ApprovalRequest
    var outcome: ApprovalOutcome?

    var id: String { request.requestId }
    var isOpen: Bool { outcome == nil }
}
