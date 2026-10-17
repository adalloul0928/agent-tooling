import AgentToolingCore
import SwiftUI

/// The conversation on the left of the creator: the opening guidance before a
/// word is exchanged, the running transcript once there is one, and the
/// composer underneath.
///
/// Every piece of state it touches belongs to the sheet and is handed in as a
/// binding, a value, or a closure, so the sheet keeps owning the conversation
/// and deciding when a turn starts and stops.
struct SkillCreatorConversationPane: View {
    let session: WorkspaceSkillDraftSession
    let client: ClientKind
    let options: SkillCreatorOptions
    let enabledClients: [ClientKind]
    let turnIsRunning: Bool
    let validationMessage: String?
    let canSend: Bool
    @Binding var composerText: String
    @Binding var showsOptions: Bool
    @Binding var optionsState: SkillCreatorOptions
    var composerFocused: FocusState<Bool>.Binding
    let sendComposer: () -> Void
    let startOver: () -> Void
    let chooseProjectFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if session.messages.isEmpty {
                openingGuidance
            } else {
                transcript
            }
            Hairline()
            composer
        }
        .background(AgentTheme.controlBackground.opacity(Opacity.paneShade))
    }

    private var openingGuidance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Describe the skill")
                    .font(AgentFont.heading)
                Text(
                    "Say what it should accomplish, when \(client.rawValue) should reach for it, and any constraints it must follow. \(client.rawValue) may ask a few questions before it writes anything, and you can ask for changes after each draft."
                )
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                .wrapsLines()

                SkillCreatorOptionsSummary(options: options, client: client)
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(session.messages) { message in
                        SkillCreatorMessageRow(message: message, client: client)
                            .id(message.id)
                    }
                    if session.isThinking {
                        HStack(spacing: Space.md) {
                            ProgressView().controlSize(.small)
                            Text("\(client.rawValue) is working…")
                                .font(AgentFont.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Space.xs)
                        .id("thinking")
                    }
                }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: session.isThinking) { _, thinking in
                guard thinking else { return }
                withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if session.hasConversation {
                HStack {
                    Text(session.result == nil ? "Answer or add detail" : "Ask for changes")
                        .font(AgentFont.captionSemibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !session.messages.isEmpty {
                        Button("Start over") { startOver() }
                            .inlineActionStyle()
                            .font(AgentFont.caption)
                            .disabled(turnIsRunning || session.isBusy)
                    }
                }
            } else {
                HStack {
                    Text("Your first message")
                        .font(AgentFont.captionSemibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showsOptions.toggle()
                    } label: {
                        Label(showsOptions ? "Hide options" : "Options", systemImage: "slider.horizontal.3")
                    }
                    .inlineActionStyle()
                    .font(AgentFont.caption)
                    .disabled(session.isBusy)
                }
                if showsOptions {
                    SkillCreatorOptionsForm(
                        options: $optionsState, client: client, enabledClients: enabledClients,
                        chooseProjectFolder: chooseProjectFolder)
                }
            }

            TextEditor(text: $composerText)
                .font(AgentFont.body)
                .scrollContentBackground(.hidden)
                .padding(Space.md)
                .frame(minHeight: Size.composerMinHeight, maxHeight: Size.composerMaxHeight)
                .background(AgentTheme.contentBackground, in: RoundedRectangle.control)
                .overlay {
                    RoundedRectangle.control
                        .strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
                }
                .focused(composerFocused)
                .disabled(session.isBusy)
                .accessibilityLabel(session.hasConversation ? "Your reply" : "Skill description")

            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .font(AgentFont.caption)
                        .foregroundStyle(composerText.isEmpty ? Color.secondary : Color.red)
                        .lineLimit(2)
                } else {
                    Text("\(composerText.count.formatted()) / \(SkillDraftRequest.maximumInstructionCharacters.formatted())")
                        .font(AgentFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    sendComposer()
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                }
                .primaryActionStyle()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(turnIsRunning || session.isBusy || !canSend)
                .help("Send (⌘↩)")
            }
        }
        .padding(Space.xl)
    }
}

/// One line of the transcript: a person's message to the right, the assistant's
/// to the left with its brand mark, and a note set apart as neither.
struct SkillCreatorMessageRow: View {
    let message: SkillDraftMessage
    let client: ClientKind

    var body: some View {
        switch message.role {
        case .person:
            HStack {
                Spacer(minLength: Space.huge)
                Text(message.text)
                    .font(AgentFont.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .background(AgentTheme.selection.opacity(Opacity.messageWash), in: RoundedRectangle.card)
            }
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            HStack(alignment: .top, spacing: Space.lg) {
                ClientBrandIcon(client: client, size: Size.tileSmall)
                    .frame(width: Size.tileSmall, height: Size.tileSmall)
                    .accessibilityHidden(true)
                Text(message.text)
                    .font(AgentFont.body)
                    .textSelection(.enabled)
                    .wrapsLines()
                Spacer(minLength: Space.xxl)
            }
            .accessibilityLabel("\(client.rawValue) said: \(message.text)")
        case .note:
            Label(message.text, systemImage: "info.circle")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
        }
    }
}

/// Shown in place of the two panes when the chosen assistant has no skill
/// creator yet: why it is needed, the exact command that installs it, and a
/// button to run that command.
struct SkillCreatorInstallOffer: View {
    let client: ClientKind
    let reason: String
    let install: [SkillCreatorInstallCommand]
    let session: WorkspaceSkillDraftSession
    @Binding var turnTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: Space.xxl) {
            Spacer()
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: Size.heroSymbolLarge, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: Space.sm) {
                Text("\(client.rawValue) needs its skill creator first")
                    .font(AgentFont.title)
                Text(reason)
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Size.proseMaxWidth)
            }
            if install.isEmpty {
                Text("Agent Tooling does not know a command that installs it here.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(install.enumerated()), id: \.offset) { _, command in
                        Text("\(command.executable) \(command.arguments.joined(separator: " "))")
                            .font(AgentFont.mono)
                            .textSelection(.enabled)
                    }
                }
                .padding(Space.lg)
                .background(AgentTheme.controlBackground, in: RoundedRectangle.control)
                Text("This runs \(client.rawValue)'s own install command and records a receipt. Nothing about your skills changes.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Size.proseMaxWidth)
                Button {
                    turnTask = Task { @MainActor in
                        await session.installSkillCreator(for: client)
                        turnTask = nil
                    }
                } label: {
                    if session.isInstalling {
                        HStack(spacing: Space.md) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Text("Install the skill creator")
                    }
                }
                .primaryActionStyle()
                .disabled(session.isBusy || turnTask != nil)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxxl)
    }
}
