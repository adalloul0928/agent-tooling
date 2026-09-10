import AgentToolingCore
import AppKit
import SwiftUI

/// Paste what another tool gave you — an `mcp add` command, a client's JSON
/// block, a bare server URL, or a SKILL.md — and see exactly what was
/// understood before anything is saved. Every field stays editable.
///
/// A SKILL.md lands in the library through the workspace's own skill intake. A
/// server definition has nowhere to land yet: the versioned workspace records
/// that a server exists and where it was asked for, and has no command for
/// admitting how to reach one. The sheet still reads it and shows what it
/// understood, and says plainly that it cannot save it, rather than pretending
/// with a button that would fail.
struct PasteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.availableClients) private var availableClients
    let workspace: WorkspaceLaunch.Workspace

    @State private var text = ""
    @State private var shape: PastedShape?
    @State private var servers: [PastedMCPServerDraft] = []
    @State private var importNotes: [String] = []
    @State private var selectedServer = 0
    @State private var serverDraft = MCPDraft()
    @State private var skill: PastedSkillImport?
    @State private var skillDraft = SkillDraft()
    @State private var failure: String?
    @State private var isSaving = false
    @State private var savedSkillName: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { skillDraft.selectedTargets.formIntersection(Set(availableClients)) }
        .frame(width: 680, height: 620)
        .background(AgentTheme.contentBackground)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            KindTile(kind: shape == .skillMarkdown ? .skill : .mcpServer, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paste to import").font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let shape {
                Text(shape.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(22)
    }

    private var subtitle: String {
        if savedSkillName != nil { return "Saved to your library" }
        if shape == .skillMarkdown { return "Check the skill this frontmatter describes" }
        if shape != nil { return "Check what was read before it is saved" }
        return "An mcp add command, a JSON block, a server URL, or a SKILL.md"
    }

    @ViewBuilder
    private var content: some View {
        if let savedSkillName {
            EmptyStateView(
                symbol: "checkmark.circle",
                title: "\(savedSkillName) is in your library",
                message:
                    "The skill was created in the managed library. Choosing where it is used is a separate reviewed "
                    + "step, and installing it in an app is another one on the Apps screen.")
        } else if shape == .skillMarkdown {
            skillReview
        } else if !servers.isEmpty {
            serverReview
        } else {
            inputStep
        }
    }

    private var footer: some View {
        HStack {
            if shape != nil, savedSkillName == nil {
                Button("Start over") { reset() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if isSaving { ProgressView().controlSize(.small) }
            if savedSkillName == nil {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) { performPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPrimaryDisabled)
                    .help(primaryHelp)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private var primaryTitle: String {
        if shape == .skillMarkdown { return "Create skill" }
        if !servers.isEmpty { return "Add server" }
        return "Read paste"
    }

    private var primaryHelp: String {
        servers.isEmpty ? "" : Self.noServerIntakeExplanation
    }

    private var isPrimaryDisabled: Bool {
        if isSaving { return true }
        if shape == .skillMarkdown { return !skillIsComplete || !canWrite }
        // No versioned command admits a server definition, so this never enables.
        if !servers.isEmpty { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performPrimaryAction() {
        if shape == .skillMarkdown {
            Task { await createSkill() }
        } else if servers.isEmpty {
            read(text)
        }
    }

    private var canWrite: Bool { workspace.library.access == .writable }

    static let noServerIntakeExplanation =
        "This workspace records that a server exists and where it was asked for. It has no command for recording "
        + "how to reach one, so there is nothing here to save it into yet."

    // MARK: - Input

    private var inputStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Paste one definition. Nothing is run: the text is read as data, bounded, and shown back to you "
                    + "before anything is saved."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .standardPanel()
                .accessibilityLabel("Pasted definition")

            HStack(spacing: 8) {
                Button {
                    readClipboard()
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("Examples: an mcp add command, {\"mcpServers\": …}, https://…, or a SKILL.md")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
    }

    // MARK: - Server review

    private var serverReview: some View {
        Form {
            Section {
                Label(Self.noServerIntakeExplanation, systemImage: "tray.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(
                    "Add it in the app itself, then check this Mac from the Apps screen: the server will appear "
                        + "here as one this workspace knows about."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if servers.count > 1 {
                Section("Servers read") {
                    Picker("Show", selection: $selectedServer) {
                        ForEach(Array(servers.enumerated()), id: \.offset) { index, server in
                            Text(server.draft.name).tag(index)
                        }
                    }
                    .accessibilityLabel("Server to show")
                    Text("\(servers.count) servers were read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("What was understood") {
                ForEach(currentNotes, id: \.self) { note in
                    Label(note, systemImage: "text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Connection") {
                TextField("Name", text: $serverDraft.name)
                    .accessibilityLabel("Server name")
                Picker("Transport", selection: $serverDraft.transport) {
                    ForEach(MCPTransport.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Endpoint or command", text: $serverDraft.endpoint)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Endpoint or command")
                Picker("Authentication", selection: $serverDraft.authentication) {
                    ForEach(["OAuth", "API key", "Doppler", "None"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Scope", selection: $serverDraft.scope) {
                    ForEach([ToolingScope.user, .project, .localProject, .workspace]) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                if serverDraft.scope != .user {
                    HStack {
                        TextField("Project folder", text: $serverDraft.projectRoot, prompt: Text("Choose an existing folder"))
                            .accessibilityLabel("Project folder")
                        Button("Choose…") { chooseProjectFolder() }
                    }
                }
                Button {
                    copyDefinition()
                } label: {
                    Label("Copy what was read", systemImage: "doc.on.doc")
                }
            }

            if let serverError {
                Section {
                    Label(serverError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedServer) { _, index in
            guard servers.indices.contains(index) else { return }
            serverDraft = servers[index].draft
        }
    }

    private var currentNotes: [String] {
        let notes = servers.indices.contains(selectedServer) ? servers[selectedServer].notes : []
        return importNotes + notes
    }

    /// What is wrong with the definition as read, whether or not it could be
    /// saved. A person checking a paste still deserves to be told.
    private var serverError: String? {
        let rawName = serverDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { return "The paste named no server." }
        do {
            _ = try MCPDefinitionValidator.validate(serverDraft.endpoint, transport: serverDraft.transport)
        } catch {
            return error.localizedDescription
        }
        if serverDraft.scope != .user {
            do {
                _ = try ConfigurationValidator.normalizedScopedRoot(
                    scope: serverDraft.scope, value: serverDraft.projectRoot, noun: "MCP server")
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    // MARK: - Skill review

    private var skillReview: some View {
        Form {
            Section("What was understood") {
                ForEach(skill?.notes ?? [], id: \.self) { note in
                    Label(note, systemImage: "text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(skill?.missingFields ?? [], id: \.self) { missing in
                    Label("\(missing) was not in the paste. Add it below.", systemImage: "pencil.line")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Skill") {
                TextField("Name", text: $skillDraft.name)
                    .accessibilityLabel("Skill name")
                TextField("Purpose", text: $skillDraft.purpose, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityLabel("Purpose")
            }

            Section("Triggers") {
                ForEach(0..<3, id: \.self) { index in
                    TextField("Trigger \(index + 1)", text: triggerBinding(index))
                        .accessibilityLabel("Trigger \(index + 1)")
                }
                TextField("When not to use it", text: $skillDraft.negativeTrigger)
                    .accessibilityLabel("Negative trigger")
            }

            Section("Where it goes") {
                Text(
                    "The skill is created in the managed library first. Choosing which apps use it is a separate "
                        + "reviewed step, and installing it is another one on the Apps screen."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if !canWrite {
                    Label(
                        "This workspace is open for review, so nothing can be saved into it.",
                        systemImage: "lock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var skillIsComplete: Bool {
        !skillDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !skillDraft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func triggerBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { skillDraft.triggers.indices.contains(index) ? skillDraft.triggers[index] : "" },
            set: { value in
                while skillDraft.triggers.count <= index { skillDraft.triggers.append("") }
                skillDraft.triggers[index] = value
            }
        )
    }

    // MARK: - Saving

    /// Writes the reviewed frontmatter into a scratch folder, captures it as
    /// immutable content, and admits it. The scratch folder is removed either
    /// way; nothing outside the workspace is touched.
    private func createSkill() async {
        guard canWrite, !isSaving else { return }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        let draft = skillDraft
        let displayName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let identifier = try WorkspaceLibrary.normalizedIdentifier(displayName)
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "paste-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.skillMarkdown(identifier: identifier, displayName: displayName, draft: draft)
                .write(
                    to: scratch.appending(path: "SKILL.md", directoryHint: .notDirectory),
                    atomically: true, encoding: .utf8)
            let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: scratch)
            guard let head = try await workspace.service.snapshot()?.document.revision.id else {
                failure = "This workspace could not be read. Nothing was saved."
                return
            }
            _ = try await workspace.service.intakeStandaloneSkill(
                .init(expectedRevisionID: head, displayName: displayName, prepared: prepared),
                prepared: prepared)
            await workspace.library.refresh()
            savedSkillName = displayName
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// The same shape a created skill has always had: frontmatter the clients
    /// read, then the sections a person fills in.
    static func skillMarkdown(identifier: String, displayName: String, draft: SkillDraft) -> String {
        let triggerLines = draft.triggers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
            .joined(separator: "\n")
        let negative = draft.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            ---
            name: \(identifier)
            description: \(yamlQuoted(draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines)))
            ---

            # \(displayName)

            ## When to use this skill

            \(triggerLines.isEmpty ? "Use this skill when the user asks for this reusable workflow." : triggerLines)

            ## When not to use this skill

            \(negative.isEmpty ? "Do not use it for work another skill already covers." : negative)

            ## Workflow

            1. Confirm the goal and the applicable scope.
            2. Inspect the relevant local state before making a change.
            3. Complete the requested workflow and report the verifiable result.
            """
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case WorkspaceSkillPreparationError.invalidSkillDefinition:
            return "The name and purpose could not be written as valid skill frontmatter. Try a simpler name."
        case is WorkspaceIdentifierError:
            return "That name cannot become a skill identifier. Use letters, numbers and dashes."
        default:
            return "The skill could not be created: \(error.localizedDescription)"
        }
    }

    // MARK: - Reading

    private func readClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            failure = "The clipboard holds no text to read."
            return
        }
        text = value
        read(value)
    }

    private func read(_ value: String) {
        do {
            switch try PastedDefinitionParser.parse(value) {
            case .mcp(let result):
                shape = result.shape
                servers = result.servers
                importNotes = result.notes
                selectedServer = 0
                serverDraft = result.servers.first?.draft ?? MCPDraft()
                skill = nil
                failure = nil
            case .skill(let result):
                shape = .skillMarkdown
                skill = result
                skillDraft = result.draft
                skillDraft.selectedTargets.formIntersection(Set(availableClients))
                servers = []
                importNotes = result.notes
                failure = nil
            }
        } catch {
            failure = error.localizedDescription
            shape = nil
            servers = []
            skill = nil
        }
    }

    private func reset() {
        shape = nil
        servers = []
        skill = nil
        importNotes = []
        failure = nil
        selectedServer = 0
    }

    private func copyDefinition() {
        let transport = serverDraft.transport.rawValue
        let summary = """
            name: \(serverDraft.name)
            transport: \(transport)
            endpoint: \(serverDraft.endpoint)
            authentication: \(serverDraft.authentication)
            scope: \(serverDraft.scope.displayName)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the MCP project folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !serverDraft.projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: serverDraft.projectRoot, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        serverDraft.projectRoot = url.standardizedFileURL.path(percentEncoded: false)
    }
}
