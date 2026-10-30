import SwiftUI

/// The chat's configuration as the desktop described it: model, mode,
/// reasoning, skills and tools. The reasoning level can be chosen here when
/// the desktop offers its levels (snotra#1304); the rest is changed at the desktop.
struct ChatConfigurationView: View {
    let model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var reasoningRefused = false

    var body: some View {
        NavigationStack {
            if let configuration = model.configuration {
                list(configuration)
                    .navigationTitle("Chat settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                    .alert("The reasoning level could not be changed", isPresented: $reasoningRefused) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("The chat keeps the level it had.")
                    }
            }
        }
    }

    private func list(_ configuration: ChatConfiguration) -> some View {
        List {
            Section {
                LabeledContent("Model", value: configuration.modelLabel ?? String(localized: "None set up"))
                    .accessibilityIdentifier("configuration.model")
                LabeledContent("Mode", value: configuration.modeName)
                if configuration.canChooseReasoning, let reasoning = configuration.reasoning {
                    Picker("Reasoning", selection: reasoningSelection(reasoning)) {
                        ForEach(configuration.reasoningLevels ?? [], id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.settingReasoning)
                    .accessibilityIdentifier("configuration.reasoning")
                } else if let reasoning = configuration.reasoning {
                    LabeledContent("Reasoning", value: reasoning)
                }
            } footer: {
                if configuration.canChooseReasoning {
                    Text("A new reasoning level applies from the next message. Change the rest on your desktop.")
                } else {
                    Text("Change these on your desktop.")
                }
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
    }

    /// The chosen level goes to the desktop; the picker shows what the desktop holds.
    private func reasoningSelection(_ current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { level in
                Task {
                    if !(await model.setReasoning(level)) { reasoningRefused = true }
                }
            })
    }
}
