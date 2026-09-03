import AgentToolingCore
import AppKit
import SwiftUI

struct MCPServersView: View {
    @Environment(AppModel.self) private var model
    @Binding var request: ScreenRequest?
    @State private var query = ""
    @State private var filter: MCPFilter = .all
    @State private var selection: Set<String> = []
    @State private var activeSheet: MCPSheet?
    @State private var stackTargets: Set<ClientKind> = []
    @State private var stackError: String?
    // BEGIN live-test-console: recorded per-tool intent, shared by the row badge
    // and the detail pane's capability switches.
    @State private var capabilities = MCPCapabilityModel()
    // END live-test-console

    init(request: Binding<ScreenRequest?> = .constant(nil)) {
        _request = request
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "MCP Servers", context: toolbarContext) {
                Button {
                    activeSheet = .paste
                } label: {
                    Label("Paste…", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Read an mcp add command, a JSON block, a server URL, or a SKILL.md")
                .disabled(model.isInteractionLocked)

                Button {
                    activeSheet = .add
                } label: {
                    Label("Add server…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isInteractionLocked)
            }

            GeometryReader { proxy in
                HSplitView {
                    collectionPane
                        .frame(
                            minWidth: 350, idealWidth: 420, maxWidth: 500, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                            alignment: .topLeading)
                    detailPane
                        .frame(
                            minWidth: 540, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                            alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddMCPServerSheet { draft in adopt(draft) }
                    .environment(model)
            case .paste:
                PasteImportSheet { draft in adopt(draft) }
                    .environment(model)
            }
        }
        .onAppear {
            pruneSelection()
            consumeRequest()
        }
        .onChange(of: model.mcpServers) { _, _ in pruneSelection() }
        .onChange(of: filteredServers.map(\.id)) { _, _ in pruneSelection() }
        .onChange(of: request) { _, _ in consumeRequest() }
        // BEGIN live-test-console
        .environment(capabilities)
        .task { capabilities.activate(workspaceRoot: URL(fileURLWithPath: model.workspacePath, isDirectory: true)) }
        // END live-test-console
    }

    private func adopt(_ draft: MCPDraft) -> Bool {
        guard let server = model.addMCPServer(from: draft) else { return false }
        selection = [server.id]
        return true
    }

    private func consumeRequest() {
        guard let request else { return }
        switch request {
        case .addMCPServer: activeSheet = .add
        case .pasteImport: activeSheet = .paste
        case .selectMCPServer(let id):
            guard model.mcpServers.contains(where: { $0.id == id }) else { break }
            query = ""
            filter = .all
            selection = [id]
        case .selectPlugin: break
        }
        self.request = nil
    }

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search servers", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search MCP servers")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            HStack(spacing: 8) {
                // Sized to its content: a fixed width clipped the control, so
                // selecting a segment resized it over the search field.
                Picker("Status", selection: $filter) {
                    ForEach(MCPFilter.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .labelsHidden()
                .accessibilityLabel("MCP server status")
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 9)

            if filteredServers.isEmpty {
                EmptyStateView(
                    symbol: "network",
                    title: emptyStateTitle,
                    message: emptyStateMessage,
                    actionTitle: emptyStateActionTitle,
                    isActionEnabled: !model.mcpServers.isEmpty || !model.isInteractionLocked,
                    action: performEmptyStateAction
                )
            } else {
                List(filteredServers, selection: $selection) { server in
                    MCPCollectionRow(server: server, selected: selection.contains(server.id))
                        .tag(server.id)
                        .listRowBackground(SelectionRowBackground(selected: selection.contains(server.id)))
                        .accessibilityLabel(server.name)
                        .accessibilityValue(selection.contains(server.id) ? "Selected" : "")
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if stackedServers.count > 1 {
            MCPStackPane(
                servers: stackedServers,
                targets: $stackTargets,
                installedClients: installedClients,
                error: stackError,
                onReview: reviewStack,
                onClear: { selection = Set(stackedServers.prefix(1).map(\.id)) }
            )
        } else if let server = selectedServer {
            MCPDetailView(server: server)
                .environment(model)
        } else {
            EmptyStateView(
                symbol: "network", title: "Select a server",
                message: "Inspect local configuration, authentication boundary, target scope, and repair guidance.")
        }
    }

    /// Several picks become one plan. Selecting more than one row swaps the
    /// detail pane for the stack, so the ending is a single review.
    private var stackedServers: [MCPServer] {
        model.mcpServers
            .filter { selection.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var installedClients: Set<ClientKind> {
        Set(
            model.targetObservations
                .filter(\.isCommandAvailable)
                .compactMap(\.surface.client)
        )
    }

    private func reviewStack() {
        do {
            let plan = try StackedPlanBuilder.mcpConfigurationPlan(
                servers: stackedServers,
                targets: stackTargets,
                availableClients: installedClients
            )
            stackError = model.reviewComposedPlan(plan) ? nil : model.lastError
        } catch {
            stackError = error.localizedDescription
        }
    }

    private var filteredServers: [MCPServer] {
        model.mcpServers.filter { server in
            let matchesStatus =
                filter == .all || (filter == .attention && server.aggregateState != .healthy)
                || (filter == .connected && server.aggregateState == .healthy)
            let searchable = [server.name, server.summary, server.endpoint, server.authentication].joined(separator: " ")
            return matchesStatus && (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedServer: MCPServer? {
        guard let id = selection.first, selection.count == 1 else { return nil }
        return model.mcpServers.first { $0.id == id }
    }

    private var toolbarContext: String {
        let usable = model.mcpServers.filter { $0.aggregateState == .healthy }.count
        let base = "\(model.mcpServers.count) configured · \(usable) usable"
        return stackedServers.count > 1 ? "\(base) · \(stackedServers.count) selected" : base
    }

    private func pruneSelection() {
        let visible = filteredServers.map(\.id)
        let kept = selection.intersection(visible)
        if kept.isEmpty {
            selection = Set(visible.prefix(1))
        } else if kept != selection {
            selection = kept
        }
        if stackTargets.isEmpty {
            stackTargets = installedClients.isEmpty ? Set(ClientKind.allCases) : installedClients
        }
        stackError = nil
    }

    private var emptyStateTitle: String {
        model.mcpServers.isEmpty ? "No MCP servers yet" : "No matching servers"
    }

    private var emptyStateMessage: String {
        model.mcpServers.isEmpty
            ? "Add a server definition, choose its apps, and review every native configuration command before it runs."
            : "Clear the search or change the status filter."
    }

    private var emptyStateActionTitle: String {
        model.mcpServers.isEmpty ? "Add Server" : "Clear Filters"
    }

    private func performEmptyStateAction() {
        if model.mcpServers.isEmpty {
            activeSheet = .add
        } else {
            query = ""
            filter = .all
        }
    }
}

private enum MCPSheet: String, Identifiable {
    case add
    case paste
    var id: String { rawValue }
}

private enum MCPFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case connected = "Ready"
    case attention = "Needs setup"
    var id: String { rawValue }
}

/// The stack: several picks, one plan. It says exactly what will be reviewed
/// and refuses combinations it cannot describe honestly in a single plan.
private struct MCPStackPane: View {
    @Environment(AppModel.self) private var model
    let servers: [MCPServer]
    @Binding var targets: Set<ClientKind>
    let installedClients: Set<ClientKind>
    let error: String?
    let onReview: () -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    KindTile(kind: .mcpServer, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(servers.count) servers selected").font(.title3.weight(.semibold))
                        Text("Review them as one plan instead of one plan each.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review one plan", action: onReview)
                        .buttonStyle(.borderedProminent)
                        .disabled(targets.isEmpty || model.isInteractionLocked)
                }

                if let error {
                    AttentionBanner(title: "This stack cannot be planned yet", message: error) {
                        Button("Keep one", action: onClear)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                GroupBox("In this stack") {
                    VStack(spacing: 0) {
                        ForEach(servers) { server in
                            InfoRow(server.name, detail: "\(server.transport.rawValue) · \(server.scope)") {
                                KindTile(kind: .mcpServer, size: 26, ghost: !server.isManagedDefinition)
                            } trailing: {
                                StatusGlyph(state: server.aggregateState, size: 13)
                            }
                            if server.id != servers.last?.id { Divider().opacity(0.35) }
                        }
                    }
                }

                GroupBox("Configure for") {
                    VStack(spacing: 0) {
                        ForEach(ClientKind.allCases) { client in
                            LabeledValueRow(client.rawValue) {
                                HStack(spacing: 8) {
                                    Toggle(
                                        "Include \(client.rawValue)",
                                        isOn: Binding(
                                            get: { targets.contains(client) },
                                            set: { isOn in
                                                if isOn {
                                                    targets.insert(client)
                                                } else {
                                                    targets.remove(client)
                                                }
                                            }
                                        )
                                    )
                                    .labelsHidden()
                                    Text(installedClients.contains(client) ? "Found on this Mac" : "Not found; the plan will say so")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if client != ClientKind.allCases.last { Divider().opacity(0.35) }
                        }
                    }
                }

                Text(
                    "One plan, \(servers.count * max(targets.count, 1)) target-specific steps and a re-scan. Nothing runs until the plan is approved."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(22)
        }
    }
}

private struct MCPCollectionRow: View {
    let server: MCPServer
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: .mcpServer, size: 28, ghost: !server.isManagedDefinition)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text("\(server.transport.rawValue) · \(server.scope)")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            // BEGIN live-test-console
            MCPCapabilityBadge(serverID: server.id, selected: selected)
            // END live-test-console
            ClientMarks(present: Set(server.clients.filter(\.reportsLocalPresence).map(\.client)), size: 13)
            StatusGlyph(state: server.aggregateState, size: 13, tint: selected ? Color.white : nil)
        }
        .padding(.vertical, 6)
    }
}

private struct MCPDetailView: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    KindTile(kind: .mcpServer, size: 40, ghost: !server.isManagedDefinition)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.title3.weight(.semibold))
                        Text(server.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if setupCandidates.count == 1, let target = setupCandidates.first {
                        Button(actionTitle(for: target)) { performSetup(target) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isInteractionLocked)
                    } else if !setupCandidates.isEmpty {
                        Menu("Set up…") {
                            ForEach(setupCandidates) { target in
                                Button(actionTitle(for: target)) { performSetup(target) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isInteractionLocked)
                    } else {
                        Text(configuredSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let configuredClients = server.clients.filter(\.reportsLocalPresence)
                    if !configuredClients.isEmpty {
                        Menu("Remove…") {
                            ForEach(configuredClients) { client in
                                Button("From \(client.client.rawValue)", role: .destructive) {
                                    model.planMCPRemoval(serverID: server.id, client: client.client)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Remove \(server.name)")
                        .disabled(model.isInteractionLocked)
                    }
                }

                if let attention = server.clients.first(where: { $0.state == .attention }) {
                    AttentionBanner(title: "\(attention.client.rawValue) needs attention", message: attention.detail)
                }

                GroupBox("Client connections") {
                    ClientStatusRows(clients: server.clients)
                }

                GroupBox("Configuration") {
                    VStack(spacing: 0) {
                        LabeledValueRow(server.isManagedDefinition ? "Endpoint" : "Discovered from") {
                            Text(server.endpoint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Divider()
                        LabeledValueRow("Transport") { Text(server.transport.rawValue) }
                        Divider()
                        LabeledValueRow("Authentication") { Text(server.authentication) }
                        Divider()
                        LabeledValueRow("Scope") { Text(server.scope) }
                        if let projectRoot = server.projectRoot {
                            Divider()
                            LabeledValueRow("Project folder") {
                                LocationText(path: projectRoot)
                            }
                        }
                    }
                }

                // BEGIN live-test-console
                MCPServerCapabilitiesPane(server: server)
                // END live-test-console

                if !server.secretNames.isEmpty {
                    GroupBox("Secret references") {
                        VStack(spacing: 0) {
                            ForEach(server.secretNames, id: \.self) { secret in
                                LabeledValueRow("Environment") {
                                    HStack(spacing: 6) {
                                        Image(systemName: "lock.fill")
                                        Text(secret).font(.system(.caption, design: .monospaced))
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                if secret != server.secretNames.last { Divider() }
                            }
                        }
                    }
                }

                if let repairCommand = server.repairCommand {
                    CommandDisclosure(title: "Repair command", command: repairCommand)
                }
            }
            .padding(22)
        }
    }

    private var configuredSummary: String {
        let count = server.clients.filter(\.reportsLocalPresence).count
        return count == 0 ? "Not configured" : "Configured in \(count) app\(count == 1 ? "" : "s")"
    }

    private var setupCandidates: [ClientState] {
        server.clients
            .filter { ($0.state == .pending || $0.state == .attention) && isClientInstalled($0.client) }
            .sorted { $0.client.rawValue < $1.client.rawValue }
    }

    private func actionTitle(for target: ClientState) -> String {
        target.state == .pending ? "Add to \(target.client.rawValue)" : "Sign in to \(target.client.rawValue)"
    }

    private func performSetup(_ target: ClientState) {
        if target.state == .pending {
            model.planMCPConfiguration(server: server, targets: Set([target.client]))
        } else {
            model.authenticate(serverID: server.id, client: target.client)
        }
    }

    private func isClientInstalled(_ client: ClientKind) -> Bool {
        model.targetObservations.contains { observation in
            guard observation.isCommandAvailable else { return false }
            switch (client, observation.surface) {
            case (.claude, .claudeCode), (.claude, .claudeDesktop), (.claude, .claudeCloud),
                (.codex, .codexCLI), (.codex, .codexDesktop), (.codex, .codexCloud),
                (.gemini, .geminiCLI), (.gemini, .geminiIDE), (.gemini, .geminiCloud):
                return true
            default: return false
            }
        }
    }
}

private struct AddMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var draft = MCPDraft()
    @State private var step = 0
    @State private var pasteNotes: [String] = []
    @State private var pasteFailure: String?
    let onSave: (MCPDraft) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                KindTile(kind: .mcpServer, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add MCP server").font(.title3.weight(.semibold))
                    Text(step == 0 ? "Connection" : "Clients & review").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(step + 1) of 2").font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
            Divider()

            Form {
                if step == 0 {
                    Section("Start from a paste") {
                        HStack(spacing: 10) {
                            Button {
                                fillFromClipboard()
                            } label: {
                                Label("Paste a command, JSON, or URL", systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)
                            Text("Nothing is run; the fields below are filled in for you to check.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(pasteNotes, id: \.self) { note in
                            Label(note, systemImage: "text.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let pasteFailure {
                            Label(pasteFailure, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Section("Connection") {
                        TextField("Name", text: $draft.name, prompt: Text("Sentry"))
                            .accessibilityLabel("Server name")
                        Picker("Transport", selection: $draft.transport) {
                            ForEach(MCPTransport.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .accessibilityLabel("Transport")
                        TextField("Endpoint or command", text: $draft.endpoint, prompt: Text("https://… or npx …"))
                            .accessibilityLabel("Endpoint or command")
                        Picker("Authentication", selection: $draft.authentication) {
                            ForEach(["OAuth", "API key", "Doppler", "None"], id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityLabel("Authentication")
                        Picker("Scope", selection: $draft.scope) {
                            ForEach([ToolingScope.user, .project, .localProject, .workspace]) { scope in Text(scope.displayName).tag(scope)
                            }
                        }
                        .accessibilityLabel("Scope")
                        if draft.scope != .user {
                            HStack {
                                TextField("Project folder", text: $draft.projectRoot, prompt: Text("Choose an existing folder"))
                                    .accessibilityLabel("Project folder")
                                Button("Choose…") { chooseProjectFolder() }
                            }
                        }
                        if let connectionError {
                            Label(connectionError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Section("Install for") {
                        Toggle("Claude Code", isOn: $draft.addToClaude)
                            .accessibilityLabel("Add to Claude Code")
                        Toggle("Codex", isOn: $draft.addToCodex)
                            .accessibilityLabel("Add to Codex")
                        Toggle("Gemini CLI", isOn: $draft.addToGemini)
                            .accessibilityLabel("Add to Gemini CLI")
                    }
                    Section("Review") {
                        LabeledContent("Server", value: draft.name)
                        LabeledContent("Connection", value: draft.endpoint)
                        LabeledContent("Scope", value: draft.scope.displayName)
                        if draft.scope != .user { LabeledContent("Project folder", value: draft.projectRoot) }
                        LabeledContent("Security", value: "Secrets and OAuth remain with the selected client or provider")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.bordered) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(step == 0 ? "Continue" : "Add server") {
                    if step == 0 {
                        step = 1
                    } else if onSave(draft) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue || (step > 0 && model.isInteractionLocked))
            }
            .padding(16)
        }
        .frame(width: 680, height: 600)
        .background(AgentTheme.contentBackground)
    }

    private var canContinue: Bool {
        guard isConnectionComplete, connectionError == nil else { return false }
        return step == 0 || !draft.selectedTargets.isEmpty
    }

    private var isConnectionComplete: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return connectionError == nil
    }

    private var connectionError: String? {
        let rawName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawName.isEmpty {
            do {
                let identifier = try WorkspaceLibrary.normalizedIdentifier(rawName)
                if model.mcpServers.contains(where: { $0.id == identifier }) {
                    return "A server with this name already exists."
                }
            } catch {
                return error.localizedDescription
            }
        }
        let rawEndpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawEndpoint.isEmpty {
            do {
                _ = try MCPDefinitionValidator.validate(rawEndpoint, transport: draft.transport)
            } catch {
                return error.localizedDescription
            }
        }
        if draft.scope != .user {
            do {
                _ = try ConfigurationValidator.normalizedScopedRoot(
                    scope: draft.scope,
                    value: draft.projectRoot,
                    noun: "MCP server"
                )
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    /// Fills the form from whatever the clipboard holds, then says what it
    /// read. Every field stays editable, and nothing is saved by pasting.
    private func fillFromClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            pasteNotes = []
            pasteFailure = "The clipboard holds no text to read."
            return
        }
        do {
            switch try PastedDefinitionParser.parse(value) {
            case .mcp(let result):
                guard let server = result.servers.first else {
                    pasteFailure = "No server was found in the pasted text."
                    return
                }
                draft = server.draft
                pasteNotes =
                    result.notes + server.notes
                    + (result.servers.count > 1
                        ? ["\(result.servers.count) servers were pasted; the first one was used. Use Paste… to choose another."] : [])
                pasteFailure = nil
            case .skill:
                pasteNotes = []
                pasteFailure = "That is a SKILL.md. Close this sheet and use Paste… to import a skill."
            }
        } catch {
            pasteNotes = []
            pasteFailure = error.localizedDescription
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the MCP project folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !draft.projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.projectRoot, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.projectRoot = url.standardizedFileURL.path(percentEncoded: false)
    }
}
