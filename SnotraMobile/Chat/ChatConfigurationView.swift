import SwiftUI

/// The chat's configuration as the desktop described it: model, mode,
/// reasoning, skills and tools. Read only; it is changed at the desktop.
struct ChatConfigurationView: View {
    let configuration: ChatConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Model", value: configuration.modelLabel ?? String(localized: "None set up"))
                        .accessibilityIdentifier("configuration.model")
                    LabeledContent("Mode", value: configuration.modeName)
                    if let reasoning = configuration.reasoning {
                        LabeledContent("Reasoning", value: reasoning)
                    }
                } footer: {
                    Text("Change these on your desktop.")
                }
                if !configuration.skills.isEmpty {
                    Section("Skills") {
                        ForEach(configuration.skills, id: \.name) { skill in
                            LabeledContent(skill.name, value: skill.stateName)
                        }
                    }
                }
                if !configuration.tools.isEmpty {
                    Section("Tools") {
                        ForEach(configuration.tools, id: \.name) { tool in
                            LabeledContent(tool.name, value: tool.on ? String(localized: "On") : String(localized: "Off"))
                        }
                    }
                }
            }
            .navigationTitle("Chat settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
