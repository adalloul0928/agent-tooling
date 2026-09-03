import AgentToolingCore
import AppKit
import SwiftUI

/// Paste what another tool gave you — an `mcp add` command, a client's JSON
/// block, a bare server URL, or a SKILL.md — and see exactly what was
/// understood before anything is saved. Every field stays editable, and the
/// usual review plan still stands between this sheet and any client.
struct PasteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let onImportServer: (MCPDraft) -> Bool

    @State private var text = ""
    @State private var shape: PastedShape?
    @State private var servers: [PastedMCPServerDraft] = []
    @State private var importNotes: [String] = []
    @State private var selectedServer = 0
    @State private var serverDraft = MCPDraft()
    @State private var skill: PastedSkillImport?
    @State private var skillDraft = SkillDraft()
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
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
        if shape == .skillMarkdown { return "Check the skill this frontmatter describes" }
        if shape != nil { return "Check what was read before it is saved" }
        return "An mcp add command, a JSON block, a server URL, or a SKILL.md"
    }

    @ViewBuilder
    private var content: some View {
        if shape == .skillMarkdown {
            skillReview
        } else if !servers.isEmpty {
            serverReview
        } else {
            inputStep
        }
    }

    private var footer: some View {
        HStack {
            if shape != nil {
                Button("Start over") { reset() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(primaryTitle) { performPrimaryAction() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isPrimaryDisabled)
        }
        .padding(16)
    }

    private var primaryTitle: String {
        if shape == .skillMarkdown { return "Create skill" }
        if !servers.isEmpty { return "Add server" }
        return "Read paste"
    }

    private var isPrimaryDisabled: Bool {
        if shape == .skillMarkdown { return !skillIsComplete || model.isInteractionLocked }
        if !servers.isEmpty { return serverError != nil || model.isInteractionLocked }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performPrimaryAction() {
        if shape == .skillMarkdown {
            let draft = skillDraft
            dismiss()
            DispatchQueue.main.async { _ = model.createSkill(from: draft) }
        } else if !servers.isEmpty {
            if onImportServer(serverDraft) { dismiss() }
        } else {
            read(text)
        }
    }

    // MARK: - Input

    private var inputStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste one definition. Nothing is run: the text is read as data, bounded, and shown back to you before anything is saved.")
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
                Text("Examples: claude mcp add …, {\"mcpServers\": …}, https://…, or a SKILL.md")
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
            if servers.count > 1 {
                Section("Servers read") {
                    Picker("Import", selection: $selectedServer) {
                        ForEach(Array(servers.enumerated()), id: \.offset) { index, server in
                            Text(server.draft.name).tag(index)
                        }
                    }
                    .accessibilityLabel("Server to import")
                    Text("\(servers.count) servers were read. Import them one at a time so each one gets its own reviewed plan.")
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
            }

            Section("Install for") {
                Toggle("Claude Code", isOn: $serverDraft.addToClaude)
                Toggle("Codex", isOn: $serverDraft.addToCodex)
                Toggle("Gemini CLI", isOn: $serverDraft.addToGemini)
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

    private var serverError: String? {
        let rawName = serverDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { return "Give the server a name." }
        do {
            let identifier = try WorkspaceLibrary.normalizedIdentifier(rawName)
            if model.mcpServers.contains(where: { $0.id == identifier }) {
                return "A server with this name already exists."
            }
        } catch {
            return error.localizedDescription
        }
        do {
            _ = try MCPDefinitionValidator.validate(serverDraft.endpoint, transport: serverDraft.transport)
        } catch {
            return error.localizedDescription
        }
        if serverDraft.scope != .user {
            do {
                _ = try ConfigurationValidator.normalizedScopedRoot(
                    scope: serverDraft.scope,
                    value: serverDraft.projectRoot,
                    noun: "MCP server"
                )
            } catch {
                return error.localizedDescription
            }
        }
        if serverDraft.selectedTargets.isEmpty { return "Choose at least one app." }
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

            Section("Install for") {
                ForEach(ClientKind.allCases) { client in
                    Toggle(client.rawValue, isOn: targetBinding(client))
                }
                Text("The package is created in the managed library first. Installing into an app is a separate reviewed plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var skillIsComplete: Bool {
        !skillDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !skillDraft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && skillDraft.triggers.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !skillDraft.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !skillDraft.selectedTargets.isEmpty
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

    private func targetBinding(_ client: ClientKind) -> Binding<Bool> {
        Binding(
            get: { skillDraft.selectedTargets.contains(client) },
            set: { isOn in
                if isOn {
                    skillDraft.selectedTargets.insert(client)
                } else {
                    skillDraft.selectedTargets.remove(client)
                }
            }
        )
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
