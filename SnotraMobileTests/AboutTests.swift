import Foundation
import SwiftUI
import Testing
@testable import SnotraMobile

struct AboutTests {
    @Test func theVersionNamesTheVersionAndTheBuild() {
        #expect(AboutView.bundleVersion.wholeMatch(of: /\d+\.\d+\.\d+ \(\d+\)/) != nil)
    }

    /// The About screen and the licence note next to the word list must not drift apart.
    @Test func theCreditLinksWhatTheLicenceNoteNames() throws {
        let url = try #require(Bundle.main.url(forResource: "safety-words-v1-LICENSE", withExtension: "txt"))
        let note = try String(contentsOf: url, encoding: .utf8)
        #expect(note.contains(WordListCredit.source.absoluteString))
        #expect(note.contains(WordListCredit.licence.absoluteString))
    }

    @Test(arguments: ["en", "de"])
    func theCreditNamesTheEFFAndTheLicence(language: String) {
        let credit = Self.credit(in: language)
        #expect(credit.contains("© 2016 Electronic Frontier Foundation"))
        #expect(credit.contains("CC BY 3.0 US"))
    }

    @Test func theCreditIsTranslated() {
        #expect(Self.credit(in: "de") != Self.credit(in: "en"))
    }

    private static func credit(in language: String) -> String {
        var text = WordListCredit.text
        text.locale = Locale(identifier: language)
        return String(localized: text)
    }
}

/// The About screen as pictures, like `MirrorSnapshots`. Off unless
/// `SNOTRA_SNAPSHOT_DIR` names a folder.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"] != nil))
@MainActor
struct AboutSnapshots {
    @Test func writesTheAboutScreen() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNOTRA_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await writeHostedSnapshots([("screen", AnyView(AboutView(version: "0.1.0 (1)")))], prefix: "about", to: folder)
    }
}
