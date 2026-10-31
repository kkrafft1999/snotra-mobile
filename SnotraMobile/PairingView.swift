import SwiftUI

/// Pairing from the phone's side (concept §5.1): scan the QR code or type the
/// key, compare the six words, wait for *Allow* at the desktop.
struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: PairingFlow?
    /// Set once the word list could not be read — a broken build, not a user error.
    @State private var unavailable = false
    var makeFlow: () throws -> PairingFlow = { PairingFlow(wordList: try .bundled()) }

    var body: some View {
        NavigationStack {
            Group {
                if let flow {
                    PairingStepView(flow: flow, dismiss: { dismiss() })
                } else if unavailable || RelayEndpoint.builtIn.isEmpty {
                    ContentUnavailableView {
                        Label("Pairing isn't available yet", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text("It arrives together with remote access in Snotra on your desktop.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.background)
            .navigationTitle("Pair with your desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isPaired ? "Done" : "Close") {
                        Task {
                            if !isPaired { await flow?.cancel() }
                            dismiss()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWaiting)
        .task {
            guard flow == nil, !unavailable, !RelayEndpoint.builtIn.isEmpty else { return }
            do { flow = try makeFlow() } catch { unavailable = true }
        }
    }

    private var isPaired: Bool {
        if case .paired = flow?.step { true } else { false }
    }

    /// A claimed channel must be deleted on the way out, so swiping the sheet away is off.
    private var isWaiting: Bool {
        switch flow?.step {
        case .claiming, .comparing: true
        default: false
        }
    }
}

private struct PairingStepView: View {
    let flow: PairingFlow
    let dismiss: () -> Void

    var body: some View {
        switch flow.step {
        case .entering:
            EnterCodeView(flow: flow)
        case .claiming:
            ProgressView("Connecting to your desktop…")
        case .comparing(let phrase):
            CompareWordsView(phrase: phrase)
        case .paired:
            ContentUnavailableView {
                Label("Paired", systemImage: "checkmark.circle")
            } description: {
                Text("This iPhone is now paired with Snotra on your desktop.")
            } actions: {
                Button("Done", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.onAccent)
            }
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                Button("Try again") { flow.retry() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.onAccent)
                    .accessibilityIdentifier("retryPairing")
            }
        }
    }
}

private struct EnterCodeView: View {
    let flow: PairingFlow
    @State private var key = ""

    var body: some View {
        Form {
            if QRScannerView.isAvailable {
                Section {
                    QRScannerView { flow.submit(scanned: $0) }
                        .frame(height: 280)
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Camera")
                } footer: {
                    Text("Point the camera at the code Snotra shows on your desktop.")
                }
            }
            Section {
                TextField(text: $key, prompt: Text(verbatim: "0111-EP9D-ZH4Q-PYT4-HWWF")) {
                    Text("Key")
                }
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityIdentifier("pairingKey")
                Button("Pair", action: submit)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("submitPairingKey")
            } header: {
                Text(QRScannerView.isAvailable ? "Or type the key" : "Type the key")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func submit() {
        flow.submit(typed: key)
    }
}

private struct CompareWordsView: View {
    let phrase: SafetyPhrase

    var body: some View {
        Form {
            Section {
                ForEach(Array(phrase.words.enumerated()), id: \.offset) { index, word in
                    LabeledContent {
                        Text(verbatim: word)
                            .font(.title3.monospaced())
                            .foregroundStyle(.primary)
                    } label: {
                        Text(verbatim: "\(index + 1)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Compare the words")
            } footer: {
                Text("Check that Snotra on your desktop shows the same six words, then choose Allow there.")
            }
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for your desktop…")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("safetyPhrase")
    }
}

extension PairingFlow.Failure {
    var title: LocalizedStringResource {
        switch self {
        case .invalidCode(.notAPairingCode): "That isn't a Snotra pairing code"
        case .invalidCode(.unsupportedVersion): "This code needs a newer version of the app"
        case .invalidCode: "That key isn't right"
        case .unknownRelay: "This code points to an unknown relay"
        case .expired: "The code has expired or was already used"
        case .unreachable: "Can't reach the relay"
        case .relayRefused: "The relay refused the pairing"
        case .notAllowed: "Not allowed on the desktop"
        case .notVerified: "Pairing failed"
        case .keys: "This iPhone couldn't keep its keys"
        case .deviceUnsupported: "This iPhone can't pair"
        case .appNotAccepted: "The relay didn't accept this app"
        case .deviceFailure: "This iPhone couldn't vouch for the app"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .invalidCode(.notAPairingCode): "Scan the code in Settings › Remote access in Snotra on your desktop."
        case .invalidCode(.unsupportedVersion): "Update the app from the App Store or TestFlight, then scan the code again."
        case .invalidCode: "Compare it with the key on your desktop — a symbol may be missing or mistyped."
        case .unknownRelay: "The app only pairs through Snotra's own relay."
        case .expired: "Start pairing again on your desktop to get a new code."
        case .unreachable: "Check your internet connection and try again."
        case .relayRefused: "Try again with a new code. If it keeps happening, the relay may be misconfigured."
        case .notAllowed: "The pairing was denied or cancelled on your desktop."
        case .notVerified: "Your desktop's keys could not be verified, so nothing was kept. Start again on your desktop."
        case .keys: "Try again. If it keeps failing, restart the iPhone."
        case .deviceUnsupported: "Pairing needs App Attest, which this iPhone or this copy of the app doesn't offer. Update iOS, or install the app from TestFlight or the App Store."
        case .appNotAccepted: "Apple couldn't confirm that this copy of the app is genuine. Pairing works only with the app from TestFlight or the App Store. If that's where it came from, try again later."
        case .deviceFailure: "iOS couldn't run its security check for the app. Restart the iPhone and try again."
        }
    }
}

#Preview {
    PairingView()
}
