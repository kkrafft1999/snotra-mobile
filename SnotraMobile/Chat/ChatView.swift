import SwiftUI

/// A chat as it stands on the desktop, a running answer as it comes in, and
/// the composer: write, or stop the running turn.
struct ChatView: View {
    let mirror: DesktopMirror
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var refusal: ChatModel.SendRefusal?
    @FocusState private var composerFocused: Bool

    init(mirror: DesktopMirror, route: ChatRoute) {
        self.mirror = mirror
        _model = State(initialValue: mirror.chat(route))
    }

    private var transcript: ChatTranscript { model.transcript }
    private var workspaceActive: Bool { mirror.activeWorkspaceId == model.workspaceId }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.background)
            .navigationTitle(transcript.title.isEmpty ? String(localized: "New chat") : transcript.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { composer }
            .task {
                mirror.attach(model)
                await model.open()
            }
            .onDisappear {
                mirror.detach(model)
                Task { await model.close() }
            }
            .alert(refusalTitle, isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(refusalMessage)
            }
    }

    @ViewBuilder private var content: some View {
        switch model.loading {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                if error.reason == "not-found" {
                    Label("Chat not available", systemImage: "exclamationmark.bubble")
                } else {
                    Label("Couldn't open the chat", systemImage: "exclamationmark.bubble")
                }
            } description: {
                if error.reason == "not-found" {
                    Text("This chat no longer exists on your desktop, or its workspace is no longer open to your phone.")
                } else {
                    Text("Snotra on your desktop didn't answer in time.")
                }
            } actions: {
                Button("Try again") { Task { await model.open() } }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.onAccent)
            }
        case .loaded:
            messages
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if transcript.before != nil {
                        Button {
                            Task { await model.loadOlder() }
                        } label: {
                            if model.loadingOlder { ProgressView() } else { Text("Show earlier messages") }
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("chat.older")
                    }
                    if transcript.messages.isEmpty && transcript.live == nil && !transcript.isRunning {
                        Group {
                            if model.isNew {
                                Text("Ask something. Snotra on your desktop answers in this workspace.")
                            } else {
                                Text("This chat has no messages yet.")
                            }
                        }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(transcript.messages) { message in
                        MessageView(message: message)
                    }
                    if transcript.isRunning {
                        LiveTurnView(turn: transcript.live, state: transcript.state)
                    }
                    Color.clear.frame(height: 1).id(ChatView.bottom)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: transcript.live?.text) {
                proxy.scrollTo(ChatView.bottom, anchor: .bottom)
            }
            .onChange(of: transcript.messages.count) {
                withAnimation { proxy.scrollTo(ChatView.bottom, anchor: .bottom) }
            }
        }
        .accessibilityIdentifier("chat.messages")
    }

    private static let bottom = "bottom"

    @ViewBuilder private var composer: some View {
        if model.loading == .loaded {
            VStack(spacing: 8) {
                if !workspaceActive {
                    HStack {
                        Text("To write here, open this workspace on your desktop.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") {
                            Task { _ = await mirror.activate(model.workspaceId) }
                        }
                        .font(.footnote.weight(.semibold))
                        .disabled(mirror.switching != nil)
                        .accessibilityIdentifier("chat.activate")
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
                        .disabled(!workspaceActive)
                        .accessibilityIdentifier("chat.composer")
                    if transcript.isRunning {
                        Button {
                            Task { await model.stop() }
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.title)
                        }
                        .disabled(model.stopping)
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("chat.stop")
                    } else {
                        Button {
                            let text = draft
                            Task {
                                if let refused = await model.send(text) {
                                    refusal = refused
                                } else {
                                    draft = ""
                                }
                            }
                        } label: {
                            if model.sending {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title)
                            }
                        }
                        .disabled(!workspaceActive || model.sending
                                  || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("chat.send")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var refusalTitle: LocalizedStringResource {
        switch refusal {
        case .otherWorkspace: "Workspace not open on your desktop"
        case .busy: "Snotra is still working on this chat"
        case .tooLong: "The message is too long"
        case .noProvider: "No model set up on your desktop"
        case .notDelivered, nil: "The message didn't go out"
        }
    }

    private var refusalMessage: LocalizedStringResource {
        switch refusal {
        case .otherWorkspace: "Your desktop has another workspace open. Open this one there first; its tools work in it."
        case .busy: "Wait until the answer is done or stop it, then write again."
        case .tooLong: "Shorten it and send it again."
        case .noProvider: "Snotra on your desktop has no provider set up for this chat's model. Set one up there."
        case .notDelivered, nil: "Snotra on your desktop didn't confirm it in time. Send it again; it won't be asked twice."
        }
    }
}

/// One message: the person's on the right, Snotra's across the width.
struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                Text(AttributedString(inlineMarkdown: message.text))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 18))
                images
                if message.origin?.kind == "relay" {
                    Text("From your phone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ToolLinesView(lines: message.toolLines)
                AnswerText(text: message.text)
                images
                if message.interrupted {
                    Label("Stopped", systemImage: "stop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var images: some View {
        ForEach(Array(message.images.enumerated()), id: \.offset) { _, name in
            Label {
                if let name {
                    Text("\(name) — open it on your desktop")
                } else {
                    Text("Image — open it on your desktop")
                }
            } icon: {
                Image(systemName: "photo")
            }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The turn running now: its tool lines and its text so far.
struct LiveTurnView: View {
    let turn: ChatTranscript.LiveTurn?
    let state: DesktopMirror.ChatState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolLinesView(lines: turn?.toolLines.map(\.line) ?? [])
            if let text = turn?.text, !text.isEmpty {
                AnswerText(text: text)
            }
            if state == .needsApproval {
                Label("Waiting for your approval on your desktop", systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Group {
                        if turn == nil {
                            Text("Working on your desktop… New text appears here as it comes.")
                        } else {
                            Text("Working…")
                        }
                    }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("chat.live")
    }
}

private struct ToolLinesView: View {
    let lines: [ChatMessage.ToolLine]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line.line).lineLimit(2)
                    } icon: {
                        Image(systemName: line.status == "done" ? "checkmark.circle" : line.status == "pending" ? "clock" : "gearshape")
                            .symbolEffect(.pulse, isActive: line.status == "start")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// An answer's Markdown, block by block (`MarkdownBlock`).
struct AnswerText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text(AttributedString(inlineMarkdown: prose))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .heading(let heading):
                    Text(AttributedString(inlineMarkdown: heading))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                case .code(_, let code):
                    ScrollView(.horizontal) {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                    }
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                }
            }
        }
    }
}
