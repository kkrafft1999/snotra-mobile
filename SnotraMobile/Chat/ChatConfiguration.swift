import Foundation

/// What Snotra on the desktop runs a chat with, as `chat.configuration`
/// describes it (remote-interface.md §8.1). Read only: the phone shows it,
/// changing it stays at the desktop (O6).
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
    /// The reasoning level as the desktop names it; absent when the model takes none.
    let reasoning: String?
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
