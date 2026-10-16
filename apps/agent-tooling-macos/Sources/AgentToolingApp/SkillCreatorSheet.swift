import AgentToolingCore
import AppKit
import SwiftUI

/// Creating a skill in conversation with Claude Code or Codex, review first.
///
/// The conversation is on the left and the draft folder's files on the right,
/// re-read after every turn. Each turn is one fixed command the operation
/// policy admits, the assistant may write only inside the isolated draft
/// folder, and the managed library changes only when this sheet has shown the
/// exact files and the person chooses to save them.
///
/// The two panes, their option form, and the file-review selection live in
/// their own files (`+Conversation`, `+Draft`, `+Options`). The state they
/// read still belongs here and is handed down as bindings and values, so this
/// sheet keeps deciding when a turn starts and stops and which draft is live.
struct SkillCreatorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let workspace: WorkspaceLaunch.Workspace
    /// The queued request this creator was opened for, when it was opened for
    /// one. Accepting the draft takes that row out of the review queue; closing
    /// without accepting leaves it there.
    let pendingRequestID: UUID?
    let onCreated: (ArtifactID, Set<ClientKind>) -> Void

    @State private var session: WorkspaceSkillDraftSession
    @State private var client: ClientKind
    @State private var requestID: UUID
    @State private var composerText = ""
    @State private var options = SkillCreatorOptions()
    @State private var showsOptions = false
    @State private var turnTask: Task<Void, Never>?
    @State private var reviewSelection = SkillCreatorReviewSelection()
    @State private var loadedPendingRequest = false
    @State private var pendingAutoStart = false
    @State private var disposed = false
    @FocusState private var composerFocused: Bool

    /// The drafting service and the installer are resolved by the screen that
    /// presents this sheet and handed in, so the sheet itself never names the
    /// real ones and a test can render it without a sign-in or a process.
    init(
        workspace: WorkspaceLaunch.Workspace,
        drafting: any SkillDrafting,
        installing: any SkillCreatorInstalling = UnavailableSkillCreatorInstalling(),
        client: ClientKind? = nil,
        pendingRequestID: UUID? = nil,
        onCreated: @escaping (ArtifactID, Set<ClientKind>) -> Void
    ) {
        self.init(
            workspace: workspace,
            session: WorkspaceSkillDraftSession(
                service: workspace.service, library: workspace.library, store: workspace.store,
                drafting: drafting, installing: installing),
            client: client, pendingRequestID: pendingRequestID, onCreated: onCreated)
    }

    /// The same sheet over a session somebody else made. It is how a test draws
    /// the review pane: the draft is staged and the turn taken before the sheet
    /// exists, so laying it out runs nothing.
    init(
        workspace: WorkspaceLaunch.Workspace,
        session: WorkspaceSkillDraftSession,
        client: ClientKind? = nil,
        pendingRequestID: UUID? = nil,
        onCreated: @escaping (ArtifactID, Set<ClientKind>) -> Void
    ) {
        self.workspace = workspace
        self.pendingRequestID = pendingRequestID
        self.onCreated = onCreated
        _requestID = State(initialValue: pendingRequestID ?? UUID())
        _session = State(initialValue: session)
        _client = State(initialValue: client ?? .codex)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            if let availability = session.availability, case .missing(let reason, let install) = availability {
                SkillCreatorInstallOffer(
                    client: client, reason: reason, install: install, session: session, turnTask: $turnTask)
            } else {
                HSplitView {
                    SkillCreatorConversationPane(
                        session: session, client: client, options: options, enabledClients: enabledClients,
                        turnIsRunning: turnTask != nil, validationMessage: validationMessage, canSend: canSend,
                        composerText: $composerText, showsOptions: $showsOptions, optionsState: $options,
                        composerFocused: $composerFocused, sendComposer: sendComposer, startOver: startOver,
                        chooseProjectFolder: chooseProjectFolder)
                    .frame(minWidth: 380, idealWidth: 430, maxWidth: 520, maxHeight: .infinity)
                    SkillCreatorDraftPane(
                        result: session.result, draftIssue: session.draftIssue,
                        hasConversation: session.hasConversation, client: client, selection: $reviewSelection)
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Hairline()
            footer
        }
        .onAppear {
            if options.targets.isEmpty { options.targets = Set(enabledClients) }
            reviewSelection.selectInitial(from: session.result?.files ?? [])
        }
        // A package that arrives opens on its definition, so the review pane is
        // never a list beside an empty preview. A package rewritten in a later
        // turn is a new set of files to read.
        .onChange(of: session.result?.fingerprint) { _, _ in
            reviewSelection.reset()
            reviewSelection.selectInitial(from: session.result?.files ?? [])
        }
        .frame(width: 1_000, height: 720)
        .background(AgentTheme.contentBackground)
        .task(id: client) {
            await session.checkAvailability(for: client)
        }
        .task(id: pendingRequestID) {
            await openPendingRequestIfNeeded()
        }
        .onChange(of: workspace.library.isBusy) { _, isBusy in
            guard !isBusy, pendingAutoStart, !session.hasConversation else { return }
            pendingAutoStart = false
            sendComposer()
        }
        .onDisappear {
            turnTask?.cancel()
            guard !disposed else { return }
            disposed = true
            let session = session
            let id = requestID
            Task { await session.abandon(requestID: id) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.lg) {
            ClientBrandIcon(client: client, size: Size.tile)
                .frame(width: Size.discLarge, height: Size.discLarge)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Create a skill with \(client.rawValue)")
                    .font(AgentFont.titleLarge)
                Text(headerDetail)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // Which assistant writes the draft can change until the first
            // turn; after that the conversation belongs to one of them.
            if !session.hasConversation, pendingRequestID == nil {
                Picker("Assistant", selection: $client) {
                    ForEach(assistantChoices, id: \.self) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(session.isBusy)
                .accessibilityLabel("Assistant")
            }
        }
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
    }

    private var headerDetail: String {
        if session.result != nil {
            return "Nothing is installed until you save this draft and choose where it should be used."
        }
        return "Uses the skill creator in your signed-in \(client.rawValue). It writes only into a private draft folder."
    }

    /// The assistants this sheet can switch between: the managed ones with a
    /// skill creator, and always the one it opened with.
    private var assistantChoices: [ClientKind] {
        var choices: [ClientKind] = [.claude, .codex].filter { (choice: ClientKind) in workspace.device.isEnabled(choice) }
        if !choices.contains(client) { choices.append(client) }
        return choices
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: Space.lg) {
            if let message = session.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(AgentFont.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 520, alignment: .leading)
            } else if session.isThinking {
                ProgressView()
                    .controlSize(.small)
                Text("\(client.rawValue) is working on the draft…")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            } else if pendingAutoStart {
                ProgressView()
                    .controlSize(.small)
                Text("Finishing the current library read before opening \(client.rawValue)…")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            } else if session.isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving the reviewed skill…")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            } else if let result = session.result {
                Label(reviewSelection.progress(for: result), systemImage: "eye")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing is saved until you press Save.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(session.isThinking ? "Stop" : "Close") {
                close()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(session.isSaving || session.isInstalling)

            if let result = session.result {
                Button("Save skill and choose where it is used") {
                    save(result)
                }
                .primaryActionStyle()
                .disabled(
                    turnTask != nil
                        || session.isBusy
                        || !session.canWrite
                        || !reviewSelection.allReviewed(in: result)
                )
                .help(reviewSelection.allReviewed(in: result) ? "Admits the reviewed package to your library" : reviewSelection.progress(for: result))
            }
        }
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
    }

    // MARK: - Rules

    /// The apps this Mac manages. Every other client is one this Mac was told
    /// not to touch, so it is not offered as a destination.
    private var enabledClients: [ClientKind] {
        workspace.device.managedClients
    }

    private var canSend: Bool {
        validationMessage == nil && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerTooLong: Bool {
        composerText.count > SkillDraftRequest.maximumInstructionCharacters
            || composerText.lengthOfBytes(using: .utf8) > SkillDraftRequest.maximumInstructionBytes
    }

    private var validationMessage: String? {
        options.validationMessage(
            isManagingClient: workspace.device.isEnabled(client), client: client,
            composerTooLong: composerTooLong, hasConversation: session.hasConversation)
    }

    // MARK: - Actions

    /// Sends what is in the composer: the opening message when no conversation
    /// exists yet, a reply otherwise.
    private func sendComposer() {
        guard canSend, turnTask == nil else { return }
        let text = composerText
        composerText = ""
        showsOptions = false
        if session.hasConversation {
            turnTask = Task { @MainActor in
                await session.send(text, client: client)
                turnTask = nil
                composerFocused = true
            }
        } else {
            let request = options.makeRequest(id: requestID, client: client, instruction: text)
            turnTask = Task { @MainActor in
                await session.start(request)
                turnTask = nil
                composerFocused = true
            }
        }
    }

    private func save(_ result: SkillDraftResult) {
        guard turnTask == nil, !session.isBusy else { return }
        turnTask = Task { @MainActor in
            defer { turnTask = nil }
            guard let artifactID = await session.adopt(resolving: pendingRequestID) else { return }
            disposed = true
            onCreated(artifactID, Set(result.request.targets))
            dismiss()
        }
    }

    private func startOver() {
        guard turnTask == nil else { return }
        turnTask = Task { @MainActor in
            reviewSelection.reset()
            await session.startOver()
            requestID = pendingRequestID ?? UUID()
            turnTask = nil
        }
    }

    private func close() {
        let runningTask = turnTask
        runningTask?.cancel()
        guard !disposed else {
            dismiss()
            return
        }
        disposed = true
        let session = session
        let id = requestID
        Task { @MainActor in
            await runningTask?.value
            await session.abandon(requestID: id)
            dismiss()
        }
    }

    private func openPendingRequestIfNeeded() async {
        guard !loadedPendingRequest, let pendingRequestID else { return }
        loadedPendingRequest = true
        guard let request = await session.loadRequest(id: pendingRequestID) else { return }
        requestID = request.id
        client = request.client
        composerText = request.instruction
        options.proposedName = request.proposedName ?? ""
        options.scope = request.scope == .localProject ? .project : request.scope
        options.projectRoot = request.projectRoot ?? ""
        options.targets = Set(request.targets).intersection(Set(enabledClients))
        // The request was written by something that could not check whether
        // the creator is installed. Look first; the offer to install shows
        // instead of a failed first turn.
        await session.checkAvailability(for: client)
        guard session.availability?.isAvailable == true else { return }
        if workspace.library.isBusy {
            pendingAutoStart = true
        } else {
            sendComposer()
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !options.projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: options.projectRoot, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        options.projectRoot = url.standardizedFileURL.path(percentEncoded: false)
    }
}
