import SwiftUI

/// The app's name and version, and the credit for the word list the safety
/// phrase draws on (concept §8). CC BY 3.0 US asks for the credit, a link to
/// the licence and a note of what was changed — the same as
/// `safety-words-v1-LICENSE.txt` says next to the data.
struct AboutView: View {
    var version = AboutView.bundleVersion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: version)
                        .accessibilityIdentifier("about.version")
                }
                Section {
                    Text(WordListCredit.text)
                    Link("Word list at the EFF", destination: WordListCredit.source)
                        .accessibilityIdentifier("about.wordList")
                    Link("Licence: CC BY 3.0 US", destination: WordListCredit.licence)
                        .accessibilityIdentifier("about.licence")
                } header: {
                    Text("Word list")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.background)
            .navigationTitle("About Snotra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("about.done")
                }
            }
        }
    }

    /// `0.1.0 (1)`: the version and, in brackets, the build.
    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// The EFF short word list 2.0 and its licence, as the About screen names them.
enum WordListCredit {
    static let source = URL(string: "https://www.eff.org/dice")!
    static let licence = URL(string: "https://creativecommons.org/licenses/by/3.0/us/")!
    static let text: LocalizedStringResource = "The words you compare when pairing come from the EFF short word list 2.0, © 2016 Electronic Frontier Foundation, licensed under Creative Commons Attribution 3.0 United States (CC BY 3.0 US). The dice numbers were dropped; order and spelling are as published."
}

#Preview {
    AboutView(version: "0.1.0 (1)")
}
