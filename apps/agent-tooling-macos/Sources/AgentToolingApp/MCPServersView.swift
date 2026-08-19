import AgentToolingCore
import AppKit
import SwiftUI

struct MCPServersView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: MCPFilter = .all
    @State private var selectedID = ""
    @State private var showingAddServer = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "MCP Servers") {
                Button {
                    showingAddServer = true
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
        .sheet(isPresented: $showingAddServer) {
            AddMCPServerSheet { draft in
                guard let server = model.addMCPServer(from: draft) else { return false }
                selectedID = server.id
                return true
            }
            .environment(model)
        }
        .onAppear { selectFirstVisibleServerIfNeeded() }
        .onChange(of: model.mcpServers) { _, _ in selectFirstVisibleServerIfNeeded() }
        .onChange(of: filteredServers.map(\.id)) { _, _ in selectFirstVisibleServerIfNeeded() }
    }

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search servers", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search MCP servers")
                Picker("Status", selection: $filter) {
                    ForEach(MCPFilter.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .labelsHidden()
                .accessibilityLabel("MCP server status")
                .pickerStyle(.segmented)
                .frame(width: 172)
            }
            .padding(12)

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
                List(filteredServers, selection: $selectedID) { server in
                    MCPCollectionRow(server: server)
                        .tag(server.id)
                        .listRowBackground(selectedID == server.id ? AgentTheme.blue.opacity(0.13) : Color.clear)
                        .accessibilityLabel(server.name)
                        .accessibilityValue(server.id == selectedID ? "Selected" : "")
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if let server = selectedServer {
            MCPDetailView(server: server)
                .environment(model)
        } else {
            EmptyStateView(
                symbol: "network", title: "Select a server",
                message: "Inspect local configuration, authentication boundary, target scope, and repair guidance.")
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

    private var selectedServer: MCPServer? { model.mcpServers.first { $0.id == selectedID } }
    private func selectFirstVisibleServerIfNeeded() {
        guard !filteredServers.contains(where: { $0.id == selectedID }) else { return }
        selectedID = filteredServers.first?.id ?? ""
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
            showingAddServer = true
        } else {
            query = ""
            filter = .all
        }
    }
}

private enum MCPFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case connected = "Ready"
    case attention = "Needs setup"
    var id: String { rawValue }
}

private struct MCPCollectionRow: View {
    let server: MCPServer

    var body: some View {
        HStack(spacing: 11) {
            SymbolTile(symbol: server.transport == .http ? "network" : "terminal", size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.callout.weight(.semibold))
                Text(server.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(availability)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var availability: String {
        let count = server.clients.filter(\.reportsLocalPresence).count
        return count == 0 ? "Not configured" : "\(count) app\(count == 1 ? "" : "s")"
    }
}

private struct MCPDetailView: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    SymbolTile(symbol: server.transport == .http ? "network" : "terminal", size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.title2.weight(.semibold))
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
                                Text(projectRoot)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

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
    let onSave: (MCPDraft) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: "network", size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add MCP server").font(.title2.weight(.semibold))
                    Text(step == 0 ? "Connection" : "Clients & review").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(step + 1) of 2").font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
            Divider()

            Form {
                if step == 0 {
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
