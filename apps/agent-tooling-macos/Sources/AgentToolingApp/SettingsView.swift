import AgentToolingCore
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("appearance") private var appearance = "System"
    @State private var showingRecoveryImport = false
    @State private var recoveryKeyCopied = false
    @State private var category: SettingsCategory = .general

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Settings") {
                Picker("Settings category", selection: $category) {
                    ForEach(SettingsCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)

                if category == .library {
                    Button {
                        revealWorkspace()
                    } label: {
                        Label("Reveal workspace", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if category == .library {
                        SettingsGroup(title: "Local workspace", symbol: "externaldrive") {
                            SettingsValueRow(title: "Agent Tooling", detail: model.workspacePath) {
                                StatusBadge(state: .healthy, text: repositoryStatus)
                            }
                            Divider()
                            SettingsActionRow(
                                title: "Optional Git or local source",
                                detail: "Import a repository as a backup, catalog, or rollback source. It is never required for local use.",
                                actionTitle: "Import…"
                            ) {
                                chooseRepository()
                            }
                            .disabled(model.isInteractionLocked)
                            Divider()
                            SettingsValueRow(title: "Git backup", detail: model.backupConfiguration.location ?? "Not enabled") {
                                Button("Prepare Backup…") { model.prepareBackup() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(model.isInteractionLocked)
                            }
                            Divider()
                            SettingsActionRow(
                                title: "Restore a local backup",
                                detail:
                                    "Inspect a backup, compare conflicting skills, configurations, and sources, then explicitly accept its desired state.",
                                actionTitle: "Inspect…"
                            ) {
                                chooseBackup()
                            }
                            .disabled(model.isInteractionLocked)
                            if let preview = model.backupImportPreview {
                                Divider()
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(
                                            preview.conflicts.isEmpty
                                                ? "No desired-state conflicts" : "\(preview.conflicts.count) conflicts",
                                            systemImage: preview.conflicts.isEmpty ? "checkmark.shield" : "exclamationmark.triangle"
                                        )
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(preview.conflicts.isEmpty ? Color.secondary : Color.red)
                                        Spacer()
                                        Button("Review restore…") {
                                            model.acceptInspectedBackup()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(model.isInteractionLocked)
                                    }
                                    CompactPathText(path: preview.backupURL.path(percentEncoded: false))
                                    ForEach(preview.conflicts.prefix(3)) { conflict in
                                        Text(
                                            "\(conflict.kind) · \(conflict.identifier): local \(conflict.localSummary) → backup \(conflict.backupSummary)"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    }
                                    if preview.conflicts.count > 3 {
                                        Text("\(preview.conflicts.count - 3) more conflicts will be shown in the restore review.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(14)
                            }
                        }
                    }

                    if category == .library {
                        SettingsGroup(title: "Encrypted folder sync", symbol: "lock.arrow.triangle.2.circlepath") {
                            SettingsValueRow(
                                title: "Encrypted archive", detail: model.encryptedSyncConfiguration.location ?? "Not configured"
                            ) {
                                Button("Choose folder…") { chooseEncryptedSyncFolder() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(model.isInteractionLocked)
                            }
                            Divider()
                            SettingsActionRow(
                                title: "Import encrypted archive",
                                detail:
                                    "Decrypt a reviewed `agent-tooling.encrypted.json` file using the recovery key stored in this Mac’s Keychain.",
                                actionTitle: "Inspect…"
                            ) {
                                chooseEncryptedSyncArchive()
                            }
                            .disabled(model.isInteractionLocked)
                            Divider()
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Recovery key").font(.callout.weight(.medium))
                                    Text("Copy it to a password manager before moving encrypted sync to another Mac.").font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Import key…") { showingRecoveryImport = true }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(model.isInteractionLocked)
                                Button(recoveryKeyCopied ? "Copied" : "Copy key") { copyRecoveryKey() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(model.isInteractionLocked || recoveryKeyCopied)
                            }
                            .padding(14)
                            if let preview = model.encryptedSyncImportPreview {
                                Divider()
                                HStack(spacing: 10) {
                                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Decrypted preview: \(preview.libraryFileCount) managed files").font(
                                            .caption.weight(.semibold))
                                        Text("Credentials, local receipts, and observed client state are not part of the archive.").font(
                                            .caption2
                                        ).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Review restore…") { model.reviewInspectedEncryptedSyncRestore() }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(model.isInteractionLocked)
                                }
                                .padding(14)
                            }
                        }
                    }

                    if category == .policy {
                        SettingsGroup(title: "Managed policy", symbol: "building.2.crop.circle") {
                            SettingsActionRow(
                                title: "Import reviewed policy",
                                detail:
                                    "Load a data-only `agent-tooling-policy/v1` manifest from a local checkout or managed folder. It may add managed configurations and block named plugin installs.",
                                actionTitle: "Import…"
                            ) {
                                chooseManagedPolicy()
                            }
                            .disabled(model.isInteractionLocked)
                            if model.managedPolicies.isEmpty {
                                Text("No managed policy is active on this Mac.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(14)
                            } else {
                                ForEach(model.managedPolicies) { policy in
                                    Divider()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(policy.name).font(.callout.weight(.medium))
                                        Text(
                                            "\(policy.profiles.count) profiles · \(policy.requiredPluginIDs.count) required plugins · \(policy.blockedPluginIDs.count) blocked plugins"
                                        ).font(.caption).foregroundStyle(.secondary)
                                        CompactPathText(path: policy.sourcePath)
                                    }
                                    .padding(14)
                                }
                            }
                        }
                    }

                    if category == .general {
                        SettingsGroup(title: "Apps", symbol: "macbook.and.iphone") {
                            SettingsClientRow(client: .codex, detail: targetDetail(.codex), state: targetState(.codex))
                            Divider()
                            SettingsClientRow(client: .claude, detail: targetDetail(.claude), state: targetState(.claude))
                            Divider()
                            SettingsClientRow(client: .gemini, detail: targetDetail(.gemini), state: targetState(.gemini))
                        }
                    }

                    if category == .general {
                        SettingsGroup(title: "MCP runtime", symbol: "server.rack") {
                            ForEach(Array(model.mcpRuntimeStatuses.enumerated()), id: \.element.id) { index, runtime in
                                if index > 0 { Divider() }
                                SettingsValueRow(
                                    title: runtime.displayName,
                                    detail: runtime.version.map { "\(runtime.detail) Version \($0)." } ?? runtime.detail
                                ) {
                                    Text(runtime.isAvailable ? "Available" : "Not installed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if model.mcpRuntimeStatuses.isEmpty {
                                SettingsActionRow(
                                    title: "Runtime detection",
                                    detail: "Direct client configuration is the default. ToolHive support is optional.",
                                    actionTitle: "Check"
                                ) {
                                    Task { await model.refreshMCPRuntimes() }
                                }
                            } else {
                                Divider()
                                SettingsActionRow(
                                    title: "Managed ToolHive servers",
                                    detail:
                                        "\(model.mcpRuntimeServers.count) workload\(model.mcpRuntimeServers.count == 1 ? "" : "s") observed. Agent Tooling does not move existing servers automatically.",
                                    actionTitle: "Refresh"
                                ) {
                                    Task { await model.refreshMCPRuntimes() }
                                }
                            }
                        }
                    }

                    if category == .general {
                        SettingsGroup(title: "Behavior", symbol: "switch.2") {
                            SettingsToggleRow(
                                title: "Check health automatically",
                                detail: "Inspect catalog revisions and MCP availability when the app opens",
                                isOn: Binding(
                                    get: { model.automaticallyCheckHealth },
                                    set: { _ = model.setAutomaticallyCheckHealth($0) }
                                )
                            )
                            Divider()
                            SettingsToggleRow(
                                title: "Show menu bar item", detail: "Keep setup checks and sync actions one click away",
                                isOn: $showMenuBarItem
                            )
                            Divider()
                            SettingsToggleRow(
                                title: "Open at login", detail: "Start the packaged app after you sign in to this Mac",
                                isOn: launchAtLoginBinding)
                        }
                    }

                    if category == .policy {
                        SettingsGroup(title: "Safety and receipts", symbol: "lock.shield") {
                            SettingsValueRow(
                                title: "Review before changes",
                                detail: "Show the exact scope and steps before changing files or installed tooling"
                            ) {
                                Label("Always on", systemImage: "checkmark.shield")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                            SettingsValueRow(
                                title: "Sensitive output",
                                detail: "Always redact likely tokens, credentials, and secret values before storing receipts"
                            ) {
                                Label("Always on", systemImage: "checkmark.shield")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if category == .general {
                        SettingsGroup(title: "Appearance", symbol: "circle.lefthalf.filled") {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Appearance").font(.callout.weight(.medium))
                                    Text("The window material adapts to the selected system style; controls remain native and readable.")
                                        .font(
                                            .caption
                                        ).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Picker("Appearance", selection: $appearance) {
                                    ForEach(["System", "Light", "Dark"], id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 190)
                            }
                            .padding(14)
                        }
                    }

                    if category == .general {
                        SettingsGroup(title: "Diagnostics", symbol: "stethoscope") {
                            SettingsActionRow(
                                title: "Export support bundle",
                                detail:
                                    "Save app, macOS, and client versions with validation summaries and redacted receipts. Package contents, credentials, and personal paths are excluded.",
                                actionTitle: "Export…"
                            ) {
                                chooseDiagnosticDestination()
                            }
                        }
                    }

                    if category == .policy {
                        HStack(spacing: 7) {
                            Image(systemName: "hand.raised").foregroundStyle(.secondary)
                            Text(
                                "Agent Tooling runs locally. Credentials remain in your configured keychain, environment provider, or client session."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: 850)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingRecoveryImport) {
            RecoveryKeyImportSheet()
                .environment(model)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    model.presentError("Open at login could not be updated: \(error.localizedDescription)")
                }
            }
        )
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Repository"
        panel.directoryURL = URL(fileURLWithPath: model.repositoryPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            _ = model.importRepository(at: url)
        }
    }

    private func chooseDiagnosticDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agent-tooling-support.json"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        _ = model.exportDiagnostics(to: url, appVersion: version)
    }

    private func revealWorkspace() {
        guard FileManager.default.fileExists(atPath: model.workspacePath) else {
            model.presentError("The local workspace is no longer available at \(model.workspacePath).")
            return
        }
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.workspacePath) {
            model.presentError("Finder could not reveal the local workspace.")
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Inspect Backup"
        if panel.runModal() == .OK, let url = panel.url {
            model.inspectBackup(at: url)
        }
    }

    private func chooseEncryptedSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            model.prepareEncryptedSync(to: url)
        }
    }

    private func chooseEncryptedSyncArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Inspect Archive"
        if panel.runModal() == .OK, let url = panel.url {
            model.inspectEncryptedSync(at: url)
        }
    }

    private func copyRecoveryKey() {
        guard let key = model.encryptedSyncRecoveryKey() else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(key, forType: .string) else {
            model.presentError("The recovery key could not be copied to the clipboard.")
            return
        }
        recoveryKeyCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if NSPasteboard.general.string(forType: .string) == key {
                NSPasteboard.general.clearContents()
            }
            recoveryKeyCopied = false
        }
    }

    private func chooseManagedPolicy() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Import Policy"
        if panel.runModal() == .OK, let url = panel.url {
            model.importManagedPolicy(at: url)
        }
    }

    private func targetState(_ client: ClientKind) -> HealthState {
        guard let observation = model.targetObservations.first(where: { $0.surface.client == client }) else { return .pending }
        return observation.isCommandAvailable ? .healthy : .attention
    }

    private var repositoryStatus: String {
        model.repositoryPath == model.workspacePath ? "Local workspace" : "Source selected"
    }

    private func targetDetail(_ client: ClientKind) -> String {
        guard let observation = model.targetObservations.first(where: { $0.surface.client == client }) else { return "Not scanned" }
        return observation.version ?? (observation.installed ? "Configuration found; command unavailable" : "Not found on PATH")
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case library = "Library & Sync"
    case policy = "Policy & Safety"

    var id: String { rawValue }
}

private struct RecoveryKeyImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var recoveryKey = ""
    @State private var showingConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import encrypted-sync recovery key").font(.title3.weight(.semibold))
            Text("This replaces this Mac’s encrypted-sync key. Only use a key from your own secure password manager.").font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Base64 recovery key", text: $recoveryKey)
                .textFieldStyle(.roundedBorder)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review Replacement…") { showingConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recoveryKey.isEmpty || validationMessage != nil || model.isInteractionLocked)
            }
        }
        .padding(24)
        .frame(width: 520)
        .confirmationDialog(
            "Replace this Mac’s recovery key?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Recovery Key", role: .destructive) {
                if model.importEncryptedSyncRecoveryKey(recoveryKey) { dismiss() }
            }
            .disabled(model.isInteractionLocked)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing encrypted archives that use the current key will no longer open unless that key is preserved elsewhere.")
        }
    }

    private var validationMessage: String? {
        guard !recoveryKey.isEmpty else { return nil }
        do {
            _ = try EncryptedSyncService.normalizedRecoveryKey(recoveryKey)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .standardPanel()
        }
    }
}

private struct SettingsValueRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    init(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                if detail.hasPrefix("/") {
                    CompactPathText(path: detail)
                } else {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            trailing
        }
        .padding(14)
    }
}

private struct SettingsActionRow: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(14)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .padding(14)
    }
}

private struct SettingsClientRow: View {
    let client: ClientKind
    let detail: String
    let state: HealthState

    var body: some View {
        HStack(spacing: 12) {
            ClientDisc(client: client, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(client.rawValue).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(state: state, text: state == .healthy ? "Ready" : "Action")
        }
        .padding(14)
    }
}
