import SwiftUI

/// What Snotra is and where to find it, the app's version, the credit for the
/// word list the safety phrase draws on (concept §8) and the way to the legal
/// pages. CC BY 3.0 US asks for the credit, a link to
/// the licence and a note of what was changed — the same as
/// `safety-words-v1-LICENSE.txt` says next to the data.
struct AboutView: View {
    var version = AboutView.bundleVersion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(SnotraLinks.intro)
                    Link(destination: SnotraLinks.website) { Text(verbatim: "snotra-ai.dev") }
                        .accessibilityIdentifier("about.website")
                }
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
                Section {
                    Link("Legal notice (German)", destination: SnotraLinks.legalNotice)
                        .accessibilityIdentifier("about.legalNotice")
                    Link("Privacy policy (German)", destination: SnotraLinks.privacyPolicy)
                        .accessibilityIdentifier("about.privacyPolicy")
                } header: {
                    Text("Legal")
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

/// What Snotra is, and its website with the legal notice and the privacy
/// policy. The legal pages are German only, on purpose.
enum SnotraLinks {
    static let website = URL(string: "https://snotra-ai.dev")!
    static let legalNotice = URL(string: "https://snotra-ai.dev/impressum")!
    static let privacyPolicy = URL(string: "https://snotra-ai.dev/datenschutz")!
    static let intro: LocalizedStringResource = "Snotra Agent is an open-source AI agent for your desktop, built around your folder. It works with cloud or local models, with no account and no telemetry. This app is its remote: when you are away from your desk, you follow and drive the chats on your desktop, end-to-end encrypted."
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
