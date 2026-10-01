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
    @State private var proposedName = ""
    @State private var scope: ToolingScope = .user
    @State private var projectRoot = ""
    @State private var targets: Set<ClientKind> = []
    @State private var showsOptions = false
    @State private var turnTask: Task<Void, Never>?
    @State private var selectedReviewPath = ""
    @State private var reviewedPaths: Set<String> = []
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
                installOffer(reason: reason, install: install)
            } else {
                HSplitView {
                    conversationPane
                        .frame(minWidth: 380, idealWidth: 430, maxWidth: 520, maxHeight: .infinity)
                    draftPane
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Hairline()
            footer
        }
        .onAppear {
            if targets.isEmpty { targets = Set(enabledClients) }
            selectInitialFile()
        }
        // A package that arrives opens on its definition, so the review pane is
        // never a list beside an empty preview. A package rewritten in a later
        // turn is a new set of files to read.
        .onChange(of: session.result?.fingerprint) { _, _ in
            selectedReviewPath = ""
            reviewedPaths = []
            selectInitialFile()
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

    // MARK: - Install offer

    private func installOffer(reason: String, install: [SkillCreatorInstallCommand]) -> some View {
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
                    .frame(maxWidth: 520)
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
                    .frame(maxWidth: 520)
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

    // MARK: - Conversation

    private var conversationPane: some View {
        VStack(spacing: 0) {
            if session.messages.isEmpty {
                openingGuidance
            } else {
                transcript
            }
            Hairline()
            composer
        }
        .background(AgentTheme.controlBackground.opacity(0.34))
    }

    private var openingGuidance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Describe the skill")
                    .font(AgentFont.heading)
                Text("Say what it should accomplish, when \(client.rawValue) should reach for it, and any constraints it must follow. \(client.rawValue) may ask a few questions before it writes anything, and you can ask for changes after each draft.")
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                optionsSummary
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
                        messageRow(message)
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

    @ViewBuilder
    private func messageRow(_ message: SkillDraftMessage) -> some View {
        switch message.role {
        case .person:
            HStack {
                Spacer(minLength: Space.huge)
                Text(message.text)
                    .font(AgentFont.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .background(AgentTheme.selection.opacity(0.18), in: RoundedRectangle.card)
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
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.xxl)
            }
            .accessibilityLabel("\(client.rawValue) said: \(message.text)")
        case .note:
            Label(message.text, systemImage: "info.circle")
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                            .disabled(turnTask != nil || session.isBusy)
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
                if showsOptions { optionsForm }
            }

            TextEditor(text: $composerText)
                .font(AgentFont.body)
                .scrollContentBackground(.hidden)
                .padding(Space.md)
                .frame(minHeight: 72, maxHeight: 140)
                .background(AgentTheme.contentBackground, in: RoundedRectangle.control)
                .overlay {
                    RoundedRectangle.control
                        .strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
                }
                .focused($composerFocused)
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
                .disabled(turnTask != nil || session.isBusy || !canSend)
                .help("Send (⌘↩)")
            }
        }
        .padding(Space.xl)
    }

    /// What the draft will be told about itself, shown as one line until the
    /// person wants to change it.
    private var optionsSummary: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Draft options")
                .font(AgentFont.captionSemibold)
                .foregroundStyle(.secondary)
            Text(optionsSummaryText)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.contentBackground.opacity(0.6), in: RoundedRectangle.control)
    }

    private var optionsSummaryText: String {
        let name = proposedName.isEmpty ? "\(client.rawValue) chooses the name" : "named \(proposedName)"
        let offered = targets.isEmpty
            ? "offered to no app yet"
            : "offered to \(targets.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ", "))"
        let where_ = scope == .project ? "for a project" : "for you"
        return "\(name), \(where_), \(offered) after review. Change these under Options before the first message."
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            configurationField(title: "Suggested name", detail: "Optional. Leave blank to let \(client.rawValue) choose.") {
                TextField("release-readiness", text: $proposedName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Suggested skill name")
            }
            configurationField(title: "Install scope", detail: "The destination, not where \(client.rawValue) runs.") {
                WorkspaceSegmentedPicker("Install scope", selection: $scope) {
                    Text(ToolingScope.user.displayName).tag(ToolingScope.user)
                    Text(ToolingScope.project.displayName).tag(ToolingScope.project)
                }
                .labelsHidden()
            }
            if scope == .project {
                configurationField(title: "Project folder", detail: "The selected folder must already exist.") {
                    HStack(spacing: Space.md) {
                        TextField("Choose a folder", text: $projectRoot)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Project folder")
                        Button("Choose…", action: chooseProjectFolder)
                    }
                }
            }
            configurationField(
                title: "Use after review",
                detail: "The apps offered when you choose where the saved skill is used."
            ) {
                if enabledClients.isEmpty {
                    Label(
                        "This Mac is not managing any apps yet, so there is nowhere to offer the saved skill.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: Space.xl) {
                        ForEach(enabledClients, id: \.self) { target in
                            Toggle(isOn: targetBinding(target)) {
                                HStack(spacing: Space.sm) {
                                    ClientBrandIcon(client: target, size: Size.brandMark)
                                        .frame(width: Size.chipHeight, height: Size.chipHeight)
                                    Text(target.rawValue)
                                        .font(AgentFont.caption)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
        .padding(Space.lg)
        .background(AgentTheme.contentBackground.opacity(0.6), in: RoundedRectangle.control)
    }

    // MARK: - Draft

    @ViewBuilder
    private var draftPane: some View {
        if let result = session.result {
            review(result)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Draft")
                        .font(AgentFont.heading)
                    Spacer()
                }
                .padding(.horizontal, Space.xxl)
                .frame(height: Size.rowHeightTall)
                Hairline()
                if let draftIssue = session.draftIssue {
                    EmptyStateView(
                        symbol: "doc.badge.ellipsis",
                        title: "The draft is not ready to review",
                        message: "\(draftIssue) Ask \(client.rawValue) to fix it, or start over.")
                } else if session.hasConversation {
                    EmptyStateView(
                        symbol: "doc.text",
                        title: "Nothing written yet",
                        message: "\(client.rawValue) has not written the package yet. Answer its questions and the files will appear here.")
                } else {
                    EmptyStateView(
                        symbol: "doc.text",
                        title: "The draft appears here",
                        message: "Every file \(client.rawValue) writes into the draft folder is listed here after each turn, so you can read exactly what would be saved.")
                }
            }
        }
    }

    private func review(_ result: SkillDraftResult) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(result.skillName)
                        .font(AgentFont.title)
                    Text(result.description)
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.xxl)
                .padding(.vertical, Space.xl)

                Hairline()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.files, id: \.relativePath) { file in
                            Button {
                                selectedReviewPath = file.relativePath
                                reviewedPaths.insert(file.relativePath)
                            } label: {
                                HStack(spacing: Space.lg) {
                                    Image(systemName: file.isExecutable ? "terminal" : "doc")
                                        .foregroundStyle(file.isExecutable ? Color.orange : Color.secondary)
                                        .frame(width: Size.glyphSlot)
                                    VStack(alignment: .leading, spacing: Space.xxs) {
                                        Text(file.relativePath)
                                            .font(AgentFont.bodyMedium)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                            .font(AgentFont.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if file.isExecutable {
                                        Text("Executable")
                                            .font(AgentFont.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    if reviewedPaths.contains(file.relativePath) {
                                        Image(systemName: "checkmark")
                                            .font(AgentFont.caption)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Reviewed")
                                    }
                                }
                                .padding(.horizontal, Space.xl)
                                .frame(minHeight: Size.rowHeight)
                                .contentShape(Rectangle())
                                .background(
                                    selectedReviewPath == file.relativePath
                                        ? AgentTheme.controlBackground
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                            Hairline()
                        }
                    }
                }
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300, maxHeight: .infinity)
            .background(AgentTheme.controlBackground.opacity(0.34))

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(selectedReviewFile(in: result)?.relativePath ?? "Select a file")
                        .font(AgentFont.heading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        guard let file = selectedReviewFile(in: result) else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([
                            result.packageURL.appending(path: file.relativePath, directoryHint: .notDirectory)
                        ])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .secondaryActionStyle()
                    .controlSize(.small)
                    .disabled(selectedReviewFile(in: result) == nil)

                    Button {
                        guard let content = selectedReviewContent(in: result) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .secondaryActionStyle()
                    .controlSize(.small)
                    .disabled(selectedReviewContent(in: result) == nil)
                }
                .padding(.horizontal, Space.xxl)
                .frame(height: Size.rowHeightTall)

                Hairline()

                if let content = selectedReviewContent(in: result) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(content)
                            .font(AgentFont.monoBody)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(Space.xxl)
                    }
                    .background(AgentTheme.contentBackground)
                } else {
                    EmptyStateView(
                        symbol: "doc.questionmark",
                        title: "Preview unavailable",
                        message: "Reveal this file in Finder to inspect its contents."
                    )
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
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
                Label(reviewProgress(for: result), systemImage: "eye")
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
                        || !allFilesReviewed(in: result)
                )
                .help(allFilesReviewed(in: result) ? "Admits the reviewed package to your library" : reviewProgress(for: result))
            }
        }
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
    }

    private func configurationField<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(AgentFont.captionSemibold)
            Text(detail)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
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
        if !workspace.device.isEnabled(client) {
            return "This Mac is not managing \(client.rawValue), so it cannot be asked to write a skill. Turn it on in Choose apps first."
        }
        if composerTooLong {
            return "Shorten the message before sending it."
        }
        if session.hasConversation { return nil }
        if !proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (try? WorkspaceLibrary.normalizedIdentifier(proposedName)) == nil
        {
            return "The suggested name must use lowercase letters, numbers, and single hyphens."
        }
        if scope == .project, !projectFolderIsValid {
            return "Choose an existing project folder under Options."
        }
        if targets.isEmpty {
            return "Choose at least one app under Options to offer this skill to."
        }
        return nil
    }

    private var projectFolderIsValid: Bool {
        var isDirectory: ObjCBool = false
        let path = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/")
            && path != "/"
            && path.count <= WorkspaceLibrary.maximumProjectPathLength
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func targetBinding(_ target: ClientKind) -> Binding<Bool> {
        Binding(
            get: { targets.contains(target) },
            set: { enabled in
                if enabled {
                    targets.insert(target)
                } else {
                    targets.remove(target)
                }
            }
        )
    }

    private func makeRequest() -> SkillDraftRequest {
        SkillDraftRequest(
            id: requestID,
            client: client,
            instruction: composerText,
            proposedName: proposedName.isEmpty ? nil : proposedName,
            scope: scope,
            projectRoot: scope == .project ? projectRoot : nil,
            targets: targets.sorted { $0.rawValue < $1.rawValue }
        )
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
            var request = makeRequest()
            request.instruction = text
            turnTask = Task { @MainActor in
                await session.start(request)
                turnTask = nil
                composerFocused = true
            }
        }
    }

    /// Opens the generated definition, and counts it as read. Every other file
    /// still has to be opened before the draft can be saved.
    private func selectInitialFile() {
        guard let files = session.result?.files, !files.isEmpty, selectedReviewPath.isEmpty else { return }
        let initialPath =
            files.first { $0.relativePath.hasSuffix("/SKILL.md") }?.relativePath
            ?? files[0].relativePath
        selectedReviewPath = initialPath
        reviewedPaths = [initialPath]
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
            selectedReviewPath = ""
            reviewedPaths = []
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
        proposedName = request.proposedName ?? ""
        scope = request.scope == .localProject ? .project : request.scope
        projectRoot = request.projectRoot ?? ""
        targets = Set(request.targets).intersection(Set(enabledClients))
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
        if !projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectRoot = url.standardizedFileURL.path(percentEncoded: false)
    }

    private func selectedReviewFile(in result: SkillDraftResult) -> SkillDraftFile? {
        result.files.first { $0.relativePath == selectedReviewPath }
    }

    private func selectedReviewContent(in result: SkillDraftResult) -> String? {
        guard let file = selectedReviewFile(in: result) else { return nil }
        if file.relativePath.hasSuffix("/SKILL.md") {
            return result.skillMarkdown
        }
        return file.textContent
    }

    private func allFilesReviewed(in result: SkillDraftResult) -> Bool {
        result.files.allSatisfy { reviewedPaths.contains($0.relativePath) }
    }

    private func reviewProgress(for result: SkillDraftResult) -> String {
        let remaining = result.files.filter { !reviewedPaths.contains($0.relativePath) }.count
        return remaining == 0
            ? "Every generated file has been opened for review."
            : "Open \(remaining) more generated \(remaining == 1 ? "file" : "files") before saving."
    }
}
