import AgentToolingCore
import AppKit
import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @Binding var request: ScreenRequest?
    @State private var showingNewConnection = false
    @State private var connectorPendingRemoval: ConnectorRecord?
    @State private var selectedAccountID: UUID?

    init(request: Binding<ScreenRequest?> = .constant(nil)) {
        _request = request
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Accounts", context: "Metadata only · credentials stay with each provider") {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check local apps", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked)
                Button {
                    showingNewConnection = true
                } label: {
                    Label("Record connection…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isInteractionLocked)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Cloud connections")
                                .font(.title2.weight(.semibold))
                            Text(
                                "Cloud authorization stays with each provider. Record when you last checked it; Agent Tooling never copies credentials."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)

                        VStack(spacing: 0) {
                            ForEach(sortedAccountSurfaces) { account in
                                AccountSurfaceCard(account: account, selected: selectedAccountID == account.id)
                                    .id(account.id)
                                if account.id != sortedAccountSurfaces.last?.id { Divider().opacity(0.35) }
                            }
                        }
                        .standardPanel()

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Recorded connections").font(.title3.weight(.semibold))
                                Spacer()
                                Text("Metadata only").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(
                                "Track who owns each authorization and which local or cloud surface should expose it. This inventory intentionally contains secret references, never credential values."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            if model.visibleConnectors.isEmpty {
                                EmptyStateView(
                                    symbol: "link", title: "No connections recorded",
                                    message:
                                        "Record an OAuth, API-key, or admin-managed connection after configuring it in the product that owns authorization.",
                                    actionTitle: "Record connection",
                                    isActionEnabled: !model.isInteractionLocked
                                ) {
                                    showingNewConnection = true
                                }
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(sortedConnectors) { connector in
                                        ConnectorCard(connector: connector) {
                                            connectorPendingRemoval = connector
                                        }
                                        if connector.id != sortedConnectors.last?.id { Divider().opacity(0.35) }
                                    }
                                }
                                .standardPanel()
                            }
                        }

                        GroupBox("What Agent Tooling will never do") {
                            VStack(alignment: .leading, spacing: 9) {
                                Label("Copy OAuth tokens between Claude, Codex, and Gemini", systemImage: "xmark.shield")
                                Label("Claim a local plugin install changed a hosted chat product", systemImage: "xmark.shield")
                                Label("Store account credentials in a Git export", systemImage: "xmark.shield")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(4)
                        }
                    }
                    .frame(maxWidth: 860)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { consumeRequest(using: proxy) }
                .onChange(of: request) { _, _ in consumeRequest(using: proxy) }
            }
        }
        .sheet(isPresented: $showingNewConnection) {
            ConnectionEditorSheet()
                .environment(model)
        }
        .confirmationDialog(
            connectorPendingRemoval.map { "Remove \($0.name)?" } ?? "Remove connection record?",
            isPresented: Binding(
                get: { connectorPendingRemoval != nil },
                set: { if !$0 { connectorPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove connection record", role: .destructive) {
                guard let connector = connectorPendingRemoval else { return }
                model.removeConnector(id: connector.id)
                connectorPendingRemoval = nil
            }
            .disabled(model.isInteractionLocked)
            Button("Cancel", role: .cancel) { connectorPendingRemoval = nil }
        } message: {
            Text("This removes only Agent Tooling metadata. It does not revoke the provider authorization or delete a secret.")
        }
    }

    private var sortedAccountSurfaces: [AccountSurface] {
        model.visibleAccountSurfaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var sortedConnectors: [ConnectorRecord] {
        model.visibleConnectors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func consumeRequest(using proxy: ScrollViewProxy) {
        guard let request else { return }
        defer { self.request = nil }
        guard case .selectAccount(let id) = request,
            model.visibleAccountSurfaces.contains(where: { $0.id == id })
        else { return }
        selectedAccountID = id
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

private struct ConnectorCard: View {
    @Environment(AppModel.self) private var model
    let connector: ConnectorRecord
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                SymbolTile(symbol: "link", size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connector.name).font(.headline)
                    Text("\(connector.provider.isEmpty ? "Unspecified provider" : connector.provider) · \(connector.ownership.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Label("Remove record…", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Remove \(connector.name) connection record")
                .disabled(model.isInteractionLocked)
            }
            Text(connector.description).font(.caption).foregroundStyle(.secondary)
            if !connector.secretReferenceNames.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Secret references").font(.caption).foregroundStyle(.secondary)
                    Text(connector.secretReferenceNames.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            ForEach(connector.bindings) { binding in
                HStack(spacing: 8) {
                    StatusGlyph(state: binding.status == .verified ? .healthy : .pending, size: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(binding.target.displayName) · \(binding.scope.displayName)").font(.caption.weight(.semibold))
                        Text(binding.guidance).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if let date = binding.lastVerifiedAt {
                            Text("Recorded \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button(binding.status == .verified ? "Record again" : "Record verification") {
                        model.markConnectorBindingVerified(connectorID: connector.id, bindingID: binding.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(
                        binding.status == .verified
                            ? "Record another verification for \(connector.name) in \(binding.target.displayName)"
                            : "Record verification for \(connector.name) in \(binding.target.displayName)"
                    )
                    .disabled(model.isInteractionLocked)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
    }
}

private struct ConnectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var provider = ""
    @State private var owner: ConnectionOwner = .account
    @State private var target: TargetSurface = .claudeCloud
    @State private var scope: ToolingScope = .account
    @State private var secretReferences = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record a connection").font(.title2.weight(.semibold))
                    Text("No login, token, or secret value is collected here.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Form {
                TextField("Connection name", text: $name)
                    .accessibilityLabel("Connection name")
                TextField("Provider (optional)", text: $provider)
                    .accessibilityLabel("Provider, optional")
                Picker("Authorization owner", selection: $owner) {
                    ForEach(ConnectionOwner.allCases) { owner in Text(owner.displayName).tag(owner) }
                }
                .accessibilityLabel("Authorization owner")
                Picker("Expected surface", selection: $target) {
                    ForEach(model.availableTargetSurfaces) { target in Text(target.displayName).tag(target) }
                }
                .accessibilityLabel("Expected surface")
                Picker("Scope", selection: $scope) {
                    ForEach(availableScopes) { scope in Text(scope.displayName).tag(scope) }
                }
                .accessibilityLabel("Scope")
                TextField("Secret reference names, comma-separated (optional)", text: $secretReferences)
                    .accessibilityLabel("Secret reference names, comma-separated, optional")
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Record Connection") {
                    if model.addConnector(
                        name: name, provider: provider, ownership: owner, target: target, scope: scope,
                        secretReferenceNames: parsedSecretReferences)
                    {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil || model.isInteractionLocked || model.enabledClients.isEmpty)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            if !model.isClientEnabled(target.client), let first = model.availableTargetSurfaces.first { target = first }
        }
        .padding(24)
        .frame(width: 540)
        .onChange(of: target) { _, _ in
            if !availableScopes.contains(scope) { scope = availableScopes[0] }
        }
    }

    private var availableScopes: [ToolingScope] {
        target.isCloud ? [.account, .managed] : [.user, .project, .localProject, .workspace]
    }

    private var parsedSecretReferences: [String] {
        secretReferences.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    private var validationMessage: String? {
        do {
            let draft = try ConnectorValidator.validate(
                name: name,
                provider: provider,
                target: target,
                scope: scope,
                secretReferenceNames: parsedSecretReferences
            )
            if model.visibleConnectors.contains(where: {
                $0.name.localizedCaseInsensitiveCompare(draft.name) == .orderedSame
                    && $0.bindings.contains(where: { $0.target == target })
            }) {
                return "A connection with that name is already recorded for \(target.displayName)."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct AccountSurfaceCard: View {
    @Environment(AppModel.self) private var model
    let account: AccountSurface
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let client = account.surface.client {
                        ClientDisc(client: client, size: 42)
                    } else {
                        SymbolTile(symbol: "person.crop.circle", size: 42)
                    }
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name).font(.headline)
                    Text(accountSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(
                    state: account.status == .verified ? .healthy : .pending, text: account.status == .verified ? "Verified" : "Manual")
            }
            Text(account.guidance).font(.callout).foregroundStyle(.secondary)
            HStack {
                if let destination {
                    Button("Open settings", systemImage: "arrow.up.right.square") {
                        if !NSWorkspace.shared.open(destination) {
                            model.presentError("macOS could not open \(destination.absoluteString).")
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open \(account.name) settings")
                }
                Spacer()
                Button(account.status == .verified ? "Record again" : "Record verification", systemImage: "checkmark") {
                    model.markAccountSurfaceVerified(account.id)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(
                    account.status == .verified
                        ? "Record another verification for \(account.name)"
                        : "Record verification for \(account.name)"
                )
                .disabled(model.isInteractionLocked)
            }
        }
        .padding(18)
        .background(selected ? AgentTheme.blue.opacity(0.10) : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(account.name)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var destination: URL? {
        guard let value = account.verificationURL,
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil
        else { return nil }
        return components.url
    }

    private var accountSubtitle: String {
        guard let date = account.lastVerifiedAt else { return account.surface.displayName }
        return "\(account.surface.displayName) · checked \(date.formatted(.relative(presentation: .named)))"
    }

}
