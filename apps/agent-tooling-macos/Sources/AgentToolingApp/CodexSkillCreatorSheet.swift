import AgentToolingCore
import AppKit
import SwiftUI

/// A review-first authoring surface. Codex may write only into the isolated
/// draft directory; the managed library is changed only after this sheet shows
/// the exact files and the user chooses to save them.
struct CodexSkillCreatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let pendingRequestID: UUID?
    let onCreated: (Skill, Set<ClientKind>) -> Void

    @State private var requestID: UUID
    @State private var instruction = ""
    @State private var proposedName = ""
    @State private var scope: ToolingScope = .user
    @State private var projectRoot = ""
    @State private var targets: Set<ClientKind> = [.codex]
    @State private var result: CodexSkillDraftResult?
    @State private var generationTask: Task<Void, Never>?
    @State private var localError: String?
    @State private var selectedReviewPath = ""
    @State private var reviewedPaths: Set<String> = []
    @State private var loadedPendingRequest = false
    @State private var pendingAutoGeneration = false
    @State private var disposed = false
    @State private var isSaving = false

    init(pendingRequestID: UUID? = nil, onCreated: @escaping (Skill, Set<ClientKind>) -> Void) {
        self.pendingRequestID = pendingRequestID
        self.onCreated = onCreated
        _requestID = State(initialValue: pendingRequestID ?? UUID())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let result {
                review(result)
            } else {
                authoring
            }

            Divider()
            footer
        }
        .frame(width: 940, height: 700)
        .background(AgentTheme.contentBackground)
        .task(id: pendingRequestID) {
            await openPendingRequestIfNeeded()
        }
        .onChange(of: model.isInteractionLocked) { _, isLocked in
            guard !isLocked, pendingAutoGeneration, result == nil else { return }
            pendingAutoGeneration = false
            generate()
        }
        .onDisappear {
            generationTask?.cancel()
            guard let result, !disposed else { return }
            disposed = true
            Task { await model.discardCodexSkillDraft(result) }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ClientBrandIcon(client: .codex, size: 30)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(result == nil ? "Create a skill with Codex" : "Review the generated skill")
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
        if result != nil {
            return "Nothing is installed until you save this draft and approve the installation plan."
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
                        Picker("Install scope", selection: $scope) {
                            Text(ToolingScope.user.displayName).tag(ToolingScope.user)
                            Text(ToolingScope.project.displayName).tag(ToolingScope.project)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
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
                        title: "Install after review",
                        detail: "Codex creates the draft. These are optional destinations for the later install plan."
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(ClientKind.allCases.enumerated()), id: \.element) { index, client in
                                Toggle(isOn: targetBinding(client)) {
                                    HStack(spacing: 9) {
                                        ClientBrandIcon(client: client, size: 20)
                                            .frame(width: 24, height: 24)
                                        Text(client.rawValue)
                                            .font(.callout.weight(.medium))
                                    }
                                }
                                .padding(.vertical, 9)
                                if index < ClientKind.allCases.count - 1 {
                                    Divider()
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
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "doc.questionmark",
                        description: Text("Reveal this file in Finder to inspect its contents.")
                    )
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 470, alignment: .leading)
            } else if model.isGeneratingSkill {
                ProgressView()
                    .controlSize(.small)
                Text("Codex is building the draft…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if pendingAutoGeneration {
                ProgressView()
                    .controlSize(.small)
                Text("Finishing the current setup check before opening Codex…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving the reviewed skill…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let result {
                Label(reviewProgress(for: result), systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(model.isGeneratingSkill ? "Cancel" : "Close") {
                close()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            if let result {
                Button("Start over") {
                    startOver(result)
                }
                .disabled(generationTask != nil || isSaving)

                Button("Save skill and review install") {
                    save(result)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    generationTask != nil
                        || isSaving
                        || model.isInteractionLocked
                        || !allFilesReviewed(in: result)
                )
            } else {
                Button("Generate draft") {
                    generate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(generationTask != nil || !canGenerate || model.isInteractionLocked)
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

    private var canGenerate: Bool {
        validationMessage == nil
    }

    private var instructionTooLong: Bool {
        instruction.count > CodexSkillDraftRequest.maximumInstructionCharacters
            || instruction.lengthOfBytes(using: .utf8) > CodexSkillDraftRequest.maximumInstructionBytes
    }

    private var validationMessage: String? {
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
            return "Choose at least one install destination."
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
        localError = nil
        let request = makeRequest()
        generationTask = Task { @MainActor in
            let generated = await model.generateCodexSkillDraft(request)
            guard !Task.isCancelled else {
                generationTask = nil
                return
            }
            result = generated
            if let generated {
                let initialPath =
                    generated.files.first(where: { $0.relativePath.hasSuffix("/SKILL.md") })?.relativePath
                    ?? generated.files.first?.relativePath
                    ?? ""
                selectedReviewPath = initialPath
                reviewedPaths = initialPath.isEmpty ? [] : [initialPath]
            }
            if generated == nil {
                localError = model.lastError ?? "Codex did not return a reviewable skill package."
                model.dismissError()
            }
            generationTask = nil
        }
    }

    private func save(_ result: CodexSkillDraftResult) {
        guard !model.isInteractionLocked, generationTask == nil else { return }
        isSaving = true
        generationTask = Task { @MainActor in
            defer {
                isSaving = false
                generationTask = nil
            }
            if let skill = await model.adoptCodexSkillDraft(result) {
                disposed = true
                onCreated(skill, Set(result.request.targets))
                dismiss()
            } else {
                localError = model.lastError ?? "The generated skill could not be saved."
                model.dismissError()
            }
        }
    }

    private func startOver(_ result: CodexSkillDraftResult) {
        guard generationTask == nil else { return }
        generationTask = Task { @MainActor in
            await model.discardCodexSkillDraft(result)
            self.result = nil
            selectedReviewPath = ""
            reviewedPaths = []
            requestID = UUID()
            disposed = false
            localError = nil
            generationTask = nil
        }
    }

    private func close() {
        let runningTask = generationTask
        runningTask?.cancel()
        if let result, !disposed {
            disposed = true
            Task { @MainActor in
                await runningTask?.value
                await model.discardCodexSkillDraft(result)
                dismiss()
            }
        } else {
            Task { @MainActor in
                await runningTask?.value
                await model.discardCodexSkillDraftRequest(id: requestID)
                dismiss()
            }
        }
    }

    private func openPendingRequestIfNeeded() async {
        guard !loadedPendingRequest, let pendingRequestID else { return }
        loadedPendingRequest = true
        guard let request = model.loadCodexSkillDraftRequest(id: pendingRequestID) else {
            localError = model.lastError ?? "The requested skill draft is no longer available."
            model.dismissError()
            return
        }
        requestID = request.id
        instruction = request.instruction
        proposedName = request.proposedName ?? ""
        scope = request.scope == .localProject ? .project : request.scope
        projectRoot = request.projectRoot ?? ""
        targets = Set(request.targets)
        if model.isInteractionLocked {
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
