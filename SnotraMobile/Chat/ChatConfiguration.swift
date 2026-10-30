import Foundation

/// What Snotra on the desktop runs a chat with, as `chat.configuration`
/// describes it (remote-interface.md §8.1). The phone shows it; of it only
/// the reasoning level can be changed from here, with `chat.setReasoning`
/// (snotra#1304) — the rest stays at the desktop (O6).
struct ChatConfiguration: Decodable, Equatable, Sendable {
    struct Model: Decodable, Equatable, Sendable {
        let label: String
    }

    struct Skill: Decodable, Equatable, Sendable {
        let name: String
        /// `on`, `off`, or `invalid` when its SKILL.md cannot be read.
        let state: String
    }

    struct Tool: Decodable, Equatable, Sendable {
        let name: String
        let on: Bool
    }

    let model: Model
    /// `smart`, `ask-all` or `auto`.
    let mode: String
    /// The level the chat runs with, as the desktop names it; absent when the model takes none.
    var reasoning: String?
    /// The levels the chat's model takes; absent when it takes none, and from
    /// a desktop that cannot change the level from the phone.
    let reasoningLevels: [String]?
    let skills: [Skill]
    let tools: [Tool]

    /// The model's label, nil when the desktop has none for the chat.
    var modelLabel: String? {
        model.label.isEmpty ? nil : model.label
    }

    /// The line under the chat's title: the model, with its reasoning level as
    /// the desktop's model button shows it (`claude-sonnet-4-5 · high`).
    var summary: String? {
        guard let modelLabel else { return nil }
        guard let reasoning, !reasoning.isEmpty else { return modelLabel }
        return "\(modelLabel) · \(reasoning)"
    }

    /// Whether the phone may choose among the levels: the desktop lists more than one.
    var canChooseReasoning: Bool {
        reasoning != nil && (reasoningLevels?.count ?? 0) > 1
    }

    /// The permission mode under the name the desktop gives it.
    var modeName: String {
        switch mode {
        case "smart": String(localized: "Smart")
        case "ask-all": String(localized: "Always ask")
        case "auto": String(localized: "Auto")
        default: mode
        }
    }
}

extension ChatConfiguration.Skill {
    var stateName: String {
        switch state {
        case "on": String(localized: "On")
        case "off": String(localized: "Off")
        case "invalid": String(localized: "Can't be read")
        default: state
        }
    }
}
