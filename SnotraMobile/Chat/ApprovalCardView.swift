import SwiftUI

/// An approval card in the chat: what the tool wants to do, and *allow once*
/// or *deny*. Once settled, a note in its place says how and where.
struct ApprovalCardView: View {
    let card: ApprovalCard
    let answering: Bool
    let respond: (ApprovalRequest.Answer) -> Void

    private var request: ApprovalRequest { card.request }

    var body: some View {
        if let outcome = card.outcome {
            Label {
                Text(Self.note(outcome))
            } icon: {
                Image(systemName: outcome.kind == .allowed ? "checkmark.shield" : outcome.kind == .denied ? "xmark.shield" : "clock.badge.xmark")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("approval.note")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Snotra asks for your approval", systemImage: "exclamationmark.shield")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(request.reason.isEmpty ? request.tool : request.reason)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !request.tool.isEmpty && !request.reason.isEmpty {
                    Text(request.tool)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(request.targets.enumerated()), id: \.offset) { _, target in
                    Label {
                        Text(target.path).lineLimit(2).truncationMode(.middle)
                    } icon: {
                        Image(systemName: target.sensitive ? "lock.trianglebadge.exclamationmark" : "doc")
                    }
                    .font(.system(.footnote, design: .monospaced))
                }
                ForEach(Array(request.sandbox.enumerated()), id: \.offset) { _, entry in
                    Label {
                        Text(entry.allow.first ?? entry.target).lineLimit(2).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder.badge.questionmark")
                    }
                    .font(.system(.footnote, design: .monospaced))
                }
                if let preview = request.preview, !preview.text.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.text)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(8)
                            .textSelection(.enabled)
                        if preview.truncated {
                            Text("Shortened — the whole of it is on your desktop.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                }
                HStack(spacing: 12) {
                    if request.offers(.deny) {
                        Button(role: .destructive) {
                            respond(.deny)
                        } label: {
                            Text("Deny").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("approval.deny")
                    }
                    if request.offers(.allowOnce) {
                        Button {
                            respond(.allowOnce)
                        } label: {
                            Label("Allow once", systemImage: "faceid").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Color.onAccent)
                        .accessibilityIdentifier("approval.allow")
                    }
                }
                .disabled(answering)
                if !request.offers(.allowOnce) && !request.offers(.deny) {
                    Text("Answer it on your desktop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange.opacity(0.4)))
            .accessibilityIdentifier("approval.card")
        }
    }

    static func note(_ outcome: ApprovalOutcome) -> LocalizedStringResource {
        switch (outcome.kind, outcome.by) {
        case (.allowed, .thisPhone): "Allowed once from your phone"
        case (.allowed, .desktop): "Allowed on your desktop"
        case (.allowed, .other(let client)): "Allowed by \(client)"
        case (.allowed, nil): "Allowed"
        case (.denied, .thisPhone): "Denied from your phone"
        case (.denied, .desktop): "Denied on your desktop"
        case (.denied, .other(let client)): "Denied by \(client)"
        case (.denied, nil): "Denied"
        case (.expired, _): "Expired without an answer"
        case (.closed, _): "No longer open on your desktop"
        }
    }
}

#Preview("Open card") {
    ApprovalCardView(card: ApprovalCard(request: ApprovalRequest(
        requestId: "a-1", chatId: "c1", tool: "run_command", targets: [.init(path: "scripts/release.sh")],
        reason: "Runs a shell command in the workspace.",
        preview: .init(text: "npm run release -- 1.4.0", truncated: false))),
        answering: false, respond: { _ in })
        .padding()
}

#Preview("Settled") {
    ApprovalCardView(card: ApprovalCard(request: ApprovalRequest(requestId: "a-1", chatId: "c1", tool: "run_command"),
                                        outcome: ApprovalOutcome(kind: .allowed, by: .desktop)),
                     answering: false, respond: { _ in })
        .padding()
}
