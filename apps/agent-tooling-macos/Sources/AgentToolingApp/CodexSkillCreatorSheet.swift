import AgentToolingCore
import AppKit
import SwiftUI

/// A review-first authoring surface. Codex may write only into the isolated
/// draft directory; the managed library is changed only after this sheet shows
/// the exact files and the user chooses to save them.
struct CodexSkillCreatorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let workspace: WorkspaceLaunch.Workspace
    /// The queued request this creator was opened for, when it was opened for
    /// one. Accepting the draft takes that row out of the review queue; closing
    /// without accepting leaves it there.
    let pendingRequestID: UUID?
    let onCreated: (ArtifactID, Set<ClientKind>) -> Void

    @State private var session: WorkspaceSkillDraftSession
    @State private var requestID: UUID
    @State private var instruction = ""
    @State private var proposedName = ""
    @State private var scope: ToolingScope = .user
    @State private var projectRoot = ""
    @State private var targets: Set<ClientKind> = [.codex]
    @State private var generationTask: Task<Void, Never>?
    @State private var selectedReviewPath = ""
    @State private var reviewedPaths: Set<String> = []
    @State private var loadedPendingRequest = false
    @State private var pendingAutoGeneration = false
    @State private var disposed = false

    /// The drafting service is resolved by the screen that presents this sheet
    /// and handed in, so the sheet itself never names the real one and a test
    /// can render it without a Codex sign-in or a process.
    init(
        workspace: WorkspaceLaunch.Workspace,
        drafting: any CodexSkillDrafting,
        pendingRequestID: UUID? = nil,
        onCreated: @escaping (ArtifactID, Set<ClientKind>) -> Void
    ) {
        self.init(
            workspace: workspace,
            session: WorkspaceSkillDraftSession(
                service: workspace.service, library: workspace.library, store: workspace.store,
                drafting: drafting),
            pendingRequestID: pendingRequestID, onCreated: onCreated)
    }

    /// The same sheet over a session somebody else made. It is how a test draws
    /// the review pane: the draft is staged and generated before the sheet
    /// exists, so laying it out runs nothing.
    init(
        workspace: WorkspaceLaunch.Workspace,
        session: WorkspaceSkillDraftSession,
        pendingRequestID: UUID? = nil,
        onCreated: @escaping (ArtifactID, Set<ClientKind>) -> Void
    ) {
        self.workspace = workspace
        self.pendingRequestID = pendingRequestID
        self.onCreated = onCreated
        _requestID = State(initialValue: pendingRequestID ?? UUID())
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let result = session.result {
                review(result)
            } else {
                authoring
            }

            Divider()
            footer
        }
        .onAppear {
            targets.formIntersection(Set(enabledClients))
            selectInitialFile()
        }
        // A package that arrives opens on its definition, so the review pane is
        // never a list beside an empty preview.
        .onChange(of: session.result?.id) { _, _ in selectInitialFile() }
        .frame(width: 940, height: 700)
        .background(AgentTheme.contentBackground)
        .task(id: pendingRequestID) {
            await openPendingRequestIfNeeded()
        }
        .onChange(of: workspace.library.isBusy) { _, isBusy in
            guard !isBusy, pendingAutoGeneration, session.result == nil else { return }
            pendingAutoGeneration = false
            generate()
        }
        .onDisappear {
            generationTask?.cancel()
            guard !disposed else { return }
            disposed = true
            let session = session
            let id = requestID
            Task { await session.abandon(requestID: id) }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ClientBrandIcon(client: .codex, size: 30)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.result == nil ? "Create a skill with Codex" : "Review the generated skill")
                    .font(.title2.weight(.semibold))
                Text(headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 78)
    }

    private var headerDetail: String {
        if session.result != nil {
            return "Nothing is installed until you save this draft and choose where it should be used."
        }
        return "Uses the Skill Creator with your signed-in Codex account. Claude is not used for generation."
    }

    private var authoring: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Describe the workflow")
                    .font(.headline)
                Text("Tell Codex what the skill should accomplish, when it should be used, and any constraints it must follow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $instruction)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AgentTheme.controlBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(AgentTheme.separator.opacity(0.55), lineWidth: 0.5)
                    }
                    .accessibilityLabel("Skill instructions")

                HStack {
                    Text("Codex creates one portable package in an isolated draft folder.")
                    Spacer()
                    Text("\(instruction.count.formatted()) / \(CodexSkillDraftRequest.maximumInstructionCharacters.formatted())")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(instructionTooLong ? Color.red : Color.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    configurationField(
                        title: "Suggested name",
                        detail: "Optional. Codex can choose a name if this is blank."
                    ) {
                        TextField("release-readiness", text: $proposedName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Suggested skill name")
                    }

                    configurationField(
                        title: "Install scope",
                        detail: "This controls the destination, not where Codex runs."
                    ) {
                        WorkspaceSegmentedPicker("Install scope", selection: $scope) {
                            Text(ToolingScope.user.displayName).tag(ToolingScope.user)
                            Text(ToolingScope.project.displayName).tag(ToolingScope.project)
                        }
                        .labelsHidden()
                    }

                    if scope == .project {
                        configurationField(title: "Project folder", detail: "The selected folder must already exist.") {
                            HStack(spacing: 8) {
                                TextField("Choose a folder", text: $projectRoot)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Project folder")
                                Button("Choose…", action: chooseProjectFolder)
                            }
                        }
                    }

                    configurationField(
                        title: "Use after review",
                        detail: "Codex creates the draft. These are the apps offered when you choose where the saved skill is used."
                    ) {
                        if enabledClients.isEmpty {
                            Label(
                                "This Mac is not managing any apps yet, so there is nowhere to offer the saved skill.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(enabledClients.enumerated()), id: \.element) { index, client in
                                    Toggle(isOn: targetBinding(client)) {
                                        HStack(spacing: 9) {
                                            ClientBrandIcon(client: client, size: 20)
                                                .frame(width: 24, height: 24)
                                            Text(client.rawValue)
                                                .font(.callout.weight(.medium))
                                        }
                                    }
                                    .padding(.vertical, 9)
                                    if index < enabledClients.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .frame(width: 350)
            .background(AgentTheme.controlBackground.opacity(0.34))
        }
    }

    private func review(_ result: CodexSkillDraftResult) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.skillName)
                        .font(.title3.weight(.semibold))
                    Text(result.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.files, id: \.relativePath) { file in
                            Button {
                                selectedReviewPath = file.relativePath
                                reviewedPaths.insert(file.relativePath)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: file.isExecutable ? "terminal" : "doc")
                                        .foregroundStyle(file.isExecutable ? Color.orange : Color.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.relativePath)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if file.isExecutable {
                                        Text("Executable")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    if reviewedPaths.contains(file.relativePath) {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Reviewed")
                                    }
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                                .background(
                                    selectedReviewPath == file.relativePath
                                        ? AgentTheme.controlBackground
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 370, maxHeight: .infinity)
            .background(AgentTheme.controlBackground.opacity(0.34))

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(selectedReviewFile(in: result)?.relativePath ?? "Select a file")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        guard let file = selectedReviewFile(in: result) else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([
                            result.packageURL.appending(path: file.relativePath, directoryHint: .notDirectory)
                        ])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedReviewFile(in: result) == nil)

                    Button {
                        guard let content = selectedReviewContent(in: result) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedReviewContent(in: result) == nil)
                }
                .padding(.horizontal, 20)
                .frame(height: 54)

                Divider()

                if let content = selectedReviewContent(in: result) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(content)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(20)
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
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if let message = session.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 470, alignment: .leading)
            } else if session.isGenerating {
                ProgressView()
                    .controlSize(.small)
                Text("Codex is building the draft…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if pendingAutoGeneration {
                ProgressView()
                    .controlSize(.small)
                Text("Finishing the current library read before opening Codex…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if session.isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving the reviewed skill…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let result = session.result {
                Label(reviewProgress(for: result), systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(session.isGenerating ? "Cancel" : "Close") {
                close()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(session.isSaving)

            if let result = session.result {
                Button("Start over") {
                    startOver()
                }
                .disabled(generationTask != nil || session.isBusy)

                Button("Save skill and choose where it is used") {
                    save(result)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    generationTask != nil
                        || session.isBusy
                        || !session.canWrite
                        || !allFilesReviewed(in: result)
                )
            } else {
                Button("Generate draft") {
                    generate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(generationTask != nil || !canGenerate || session.isBusy)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 72)
    }

    private func configurationField<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    /// The apps this Mac manages. Every other client is one this Mac was told
    /// not to touch, so it is not offered as a destination.
    private var enabledClients: [ClientKind] {
        workspace.device.availableClients.filter(workspace.device.isEnabled)
    }

    private var canGenerate: Bool {
        validationMessage == nil
    }

    private var instructionTooLong: Bool {
        instruction.count > CodexSkillDraftRequest.maximumInstructionCharacters
            || instruction.lengthOfBytes(using: .utf8) > CodexSkillDraftRequest.maximumInstructionBytes
    }

    private var validationMessage: String? {
        if !workspace.device.isEnabled(.codex) {
            return "This Mac is not managing Codex, so it cannot be asked to write a skill. Turn Codex on in Choose apps first."
        }
        if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Describe what the skill should do."
        }
        if instructionTooLong {
            return "Shorten the instructions before generating the draft."
        }
        if !proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (try? WorkspaceLibrary.normalizedIdentifier(proposedName)) == nil
        {
            return "The suggested name must use lowercase letters, numbers, and single hyphens."
        }
        if scope == .project, !projectFolderIsValid {
            return "Choose an existing project folder."
        }
        if targets.isEmpty {
            return "Choose at least one app to offer this skill to."
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

    private func targetBinding(_ client: ClientKind) -> Binding<Bool> {
        Binding(
            get: { targets.contains(client) },
            set: { enabled in
                if enabled {
                    targets.insert(client)
                } else {
                    targets.remove(client)
                }
            }
        )
    }

    private func makeRequest() -> CodexSkillDraftRequest {
        CodexSkillDraftRequest(
            id: requestID,
            instruction: instruction,
            proposedName: proposedName.isEmpty ? nil : proposedName,
            scope: scope,
            projectRoot: scope == .project ? projectRoot : nil,
            targets: targets.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func generate() {
        guard canGenerate, generationTask == nil else { return }
        let request = makeRequest()
        generationTask = Task { @MainActor in
            await session.generate(request)
            generationTask = nil
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

    private func save(_ result: CodexSkillDraftResult) {
        guard generationTask == nil, !session.isBusy else { return }
        generationTask = Task { @MainActor in
            defer { generationTask = nil }
            guard let artifactID = await session.adopt(resolving: pendingRequestID) else { return }
            disposed = true
            onCreated(artifactID, Set(result.request.targets))
            dismiss()
        }
    }

    private func startOver() {
        guard generationTask == nil else { return }
        generationTask = Task { @MainActor in
            selectedReviewPath = ""
            reviewedPaths = []
            await session.startOver()
            requestID = pendingRequestID ?? UUID()
            generationTask = nil
        }
    }

    private func close() {
        let runningTask = generationTask
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
        instruction = request.instruction
        proposedName = request.proposedName ?? ""
        scope = request.scope == .localProject ? .project : request.scope
        projectRoot = request.projectRoot ?? ""
        targets = Set(request.targets).intersection(Set(enabledClients))
        if workspace.library.isBusy {
            pendingAutoGeneration = true
        } else {
            generate()
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

    private func selectedReviewFile(in result: CodexSkillDraftResult) -> CodexSkillDraftFile? {
        result.files.first { $0.relativePath == selectedReviewPath }
    }

    private func selectedReviewContent(in result: CodexSkillDraftResult) -> String? {
        guard let file = selectedReviewFile(in: result) else { return nil }
        if file.relativePath.hasSuffix("/SKILL.md") {
            return result.skillMarkdown
        }
        return file.textContent
    }

    private func allFilesReviewed(in result: CodexSkillDraftResult) -> Bool {
        result.files.allSatisfy { reviewedPaths.contains($0.relativePath) }
    }

    private func reviewProgress(for result: CodexSkillDraftResult) -> String {
        let remaining = result.files.filter { !reviewedPaths.contains($0.relativePath) }.count
        return remaining == 0
            ? "Every generated file has been opened for review."
            : "Open \(remaining) more generated \(remaining == 1 ? "file" : "files") before saving."
    }
}
