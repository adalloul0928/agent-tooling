import AgentToolingCore
import AppKit
import SwiftUI

/// Settings · Sync: connecting this Mac to a shared workspace repository, and
/// what the last sync actually did. Conflicts are shown as decisions to make,
/// never resolved here on the person's behalf.
///
/// The logic is `WorkspaceSyncSession`'s and `WorkspaceSyncView`'s; the visual
/// is the old Settings screen's — `TitledCard` and `InfoRow` in place of ad hoc
/// panels, the recovery-key card with its copy-to-a-password-manager caption,
/// and the old "what an archive contains" caption for encrypted folder sync.
struct SyncSettingsView: View {
    let session: WorkspaceSyncSession
    @State private var remote = ""
    @State private var checkout: URL?
    @State private var kind: WorkspaceSyncTransportKind = .git
    @State private var folder: URL?
    @State private var phrase = ""
    @State private var recoveryCopied = false

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Sync", context: session.statusText) {
                if session.isConnected {
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await session.sync() } }
                        .buttonStyle(.glassProminent).tint(AgentTheme.selection)
                        .disabled(session.isBusy)
                }
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Sync needs attention", message: message)
                    }
                    if let recovery = session.recoveryPhrase { recoveryCard(recovery) }
                    if let enrollment = session.enrollment { connectedCard(enrollment) } else { setupCard }
                    if !session.conflicts.isEmpty { conflictsCard }
                }
                .padding(WorkspaceLayout.pageInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            session.load()
            // The loop wakes often and syncs rarely: every wake-up asks the
            // scheduler, which spaces real passes apart and stops them entirely
            // while a conflict is undecided. It runs only while this screen is
            // on screen, so leaving it ends the loop.
            while !Task.isCancelled {
                await session.runScheduledPass()
                do { try await Task.sleep(for: WorkspaceSyncSession.checkInterval) } catch { return }
            }
        }
    }

    private var setupCard: some View {
        TitledCard("Use the same setup on more than one Mac") {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Agent Tooling keeps one file describing your library and where each tool belongs. Your skills' own repositories, your app settings, and anything else on this Mac are not shared."
                )
                .foregroundStyle(.secondary)
                if session.supportsEncryptedFolder {
                    Picker("How", selection: $kind) {
                        Text("A private Git repository").tag(WorkspaceSyncTransportKind.git)
                        Text("A folder your file sync already keeps in step").tag(WorkspaceSyncTransportKind.encryptedFolder)
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                }
                if kind == .git { gitSetup } else { folderSetup }
            }
            .padding(14)
        }
    }

    private var gitSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A repository is not encrypted storage. Anyone with access to it can read what is published there.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Repository") {
                TextField("https://github.com/you/workspace.git", text: $remote)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
            }
            HStack(spacing: 12) {
                Button("Choose folder on this Mac…") { chooseCheckout() }
                Text(checkout?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Connect") {
                guard let checkout else { return }
                Task {
                    await session.connect(remote: remote.trimmingCharacters(in: .whitespacesAndNewlines), checkout: checkout)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isBusy || checkout == nil || remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var folderSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Point this at a folder iCloud Drive, Dropbox or a network share already keeps in step between your Macs. What lands there is sealed: the service moving it cannot read your library."
            )
            .font(.callout).foregroundStyle(.secondary)
            SyncScopePanel()
            HStack(spacing: 12) {
                Button("Choose folder…") { chooseFolder() }
                Text(folder?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(1)
            }
            LabeledContent("Phrase from your other Mac") {
                TextField("Leave empty on your first Mac", text: $phrase)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
            }
            Button("Connect") {
                guard let folder else { return }
                Task { await session.connectFolder(folder, phrase: phrase) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isBusy || folder == nil)
        }
    }

    /// Shown once. There is nowhere else this app will show it again, so the
    /// reminder to move it into a password manager sits right beside it.
    private func recoveryCard(_ phrase: String) -> some View {
        TitledCard("Write this down now") {
            VStack(alignment: .leading, spacing: 10) {
                Text(phrase)
                    .font(.system(size: 15, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AgentTheme.contentBackground, in: RoundedRectangle(cornerRadius: 8))
                Text(
                    "This is the only way to open that folder from another Mac. Agent Tooling will not show it again, and cannot recover it for you."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Text("Copy it to a password manager before you need it on another Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(recoveryCopied ? "Copied" : "Copy") { copyRecoveryPhrase(phrase) }
                        .buttonStyle(.bordered)
                        .disabled(recoveryCopied)
                    Button("I have written it down") { session.dismissRecoveryPhrase() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
        }
    }

    private func connectedCard(_ enrollment: WorkspaceSyncEnrollment) -> some View {
        TitledCard("Connected on this Mac") {
            VStack(alignment: .leading, spacing: 0) {
                if enrollment.kind == .git {
                    InfoRow("Repository", detail: nil) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 20)
                    } trailing: {
                        Text(enrollment.remote).textSelection(.enabled).lineLimit(1)
                    }
                    Divider()
                    InfoRow("Branch", detail: nil) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 20)
                    } trailing: {
                        Text(enrollment.branch)
                    }
                    Divider()
                    InfoRow("Folder on this Mac", detail: nil) {
                        Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 20)
                    } trailing: {
                        LocationText(path: enrollment.checkoutPath)
                    }
                } else {
                    InfoRow("Shared folder", detail: "Sealed. The service moving it cannot read your library.") {
                        Image(systemName: "lock.folder").foregroundStyle(.secondary).frame(width: 20)
                    } trailing: {
                        LocationText(path: enrollment.checkoutPath)
                    }
                    Divider()
                    SyncScopePanel()
                }
                Divider()
                InfoRow("Sync on its own while the app is open", detail: session.scheduleText) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 20)
                } trailing: {
                    Toggle(
                        "Sync on its own while the app is open",
                        isOn: Binding(get: { session.isAutomatic }, set: { session.setAutomatic($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(session.isBusy)
                }
                Divider()
                Text(
                    "Syncing shares what your library holds and where each tool belongs. It does not install or remove anything in your apps; that stays a separate reviewed step."
                )
                .font(.callout).foregroundStyle(.secondary)
                .padding(14)
                Divider()
                InfoRow(
                    "Disconnect this Mac",
                    detail: enrollment.kind == .git
                        ? "The repository and its history are left alone."
                        : "The folder is left alone, and stays readable by any Mac that still has the phrase."
                ) {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary).frame(width: 20)
                } trailing: {
                    Button("Disconnect") { session.disconnect() }
                        .buttonStyle(.bordered)
                        .disabled(session.isBusy)
                }
            }
        }
    }

    private var conflictsCard: some View {
        TitledCard("Decisions to make") {
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    "Two Macs changed the same thing differently. Nothing was changed here; open each item and choose which result to keep."
                )
                .font(.callout).foregroundStyle(.secondary)
                .padding(14)
                ForEach(Array(session.conflicts.enumerated()), id: \.offset) { index, conflict in
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(conflict.kind)).fontWeight(.medium)
                        Text(conflict.detail).foregroundStyle(.secondary)
                        if session.canDecide(index) {
                            Picker(
                                "Keep",
                                selection: Binding(
                                    get: { session.choices[index] },
                                    set: { if let value = $0 { session.choose(value, at: index) } })
                            ) {
                                Text("Not decided").tag(WorkspaceConflictChoice?.none)
                                Text("Keep this Mac's version").tag(WorkspaceConflictChoice?.some(.keepLocal))
                                Text("Take the other Mac's version").tag(WorkspaceConflictChoice?.some(.takeRemote))
                            }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                            .disabled(session.isBusy)
                        } else {
                            Text("This one cannot be settled by picking a Mac. Change what each item asks for, then sync again.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
                Divider()
                HStack {
                    Button("Apply decisions") { Task { await session.applyDecisions() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || session.hasUndecidedConflicts)
                    Text(
                        session.hasUndecidedConflicts
                            ? "Decide every item above before applying."
                            : "Your decisions are applied against the newest shared version."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.standardizedFileURL
    }

    private func chooseCheckout() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        checkout = url.standardizedFileURL
    }

    /// Mirrors the old Settings screen's clipboard hygiene: copied for a
    /// person to paste into a password manager, then cleared on its own.
    private func copyRecoveryPhrase(_ phrase: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(phrase, forType: .string) else { return }
        recoveryCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if NSPasteboard.general.string(forType: .string) == phrase {
                NSPasteboard.general.clearContents()
            }
            recoveryCopied = false
        }
    }

    private func title(_ kind: WorkspaceMergeConflictKind) -> String {
        switch kind {
        case .artifactField: "Two different names or details"
        case .artifactContent: "Two different versions of the same item"
        case .deleteVersusEdit: "Removed on one Mac, changed on another"
        case .ownership: "Two different owners for one item"
        case .sourcePolicy: "Two different sources for one item"
        case .subscriptionLock: "Two different approved versions"
        case .assignmentEnablement: "Two different on or off requests"
        case .assignmentField: "Two different destinations for one request"
        case .destinationCollision: "Two items would share one place"
        case .nativeRouteCollision: "The same app package added twice"
        case .catalogSource: "Two different catalogs recorded as one"
        case .projectField: "Two different project names"
        case .unsupportedVersion: "A newer format than this app can read"
        case .invalidResult: "The combined setup did not pass its own checks"
        }
    }
}

/// The boundary of an encrypted archive, stated on the screen where somebody
/// picks the folder rather than only in the handbook. Someone choosing a cloud
/// folder is deciding what leaves this Mac, so the answer belongs in front of
/// them before they choose, not after a restore surprises them.
///
/// Ported verbatim from the old Settings screen: this is a description of what
/// travels versus what stays, not a live decrypted count — the versioned sync
/// session has nothing further to report until the folder is connected.
private struct SyncScopePanel: View {
    private static let travels = [
        "Your library: skills, plugins, servers and presets",
        "Where each tool is assigned, and to which apps",
        "Attached authoring sources",
    ]

    private static let stays = [
        "The encryption key — Keychain only",
        "Package content this Mac has not approved",
        "This Mac's own observed state and receipts",
        "Project folders and local sources",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What an archive contains").font(.callout.weight(.medium))
            HStack(alignment: .top, spacing: 22) {
                column(title: "Travels to another Mac", symbol: "checkmark.circle.fill", tint: AgentTheme.ok, items: Self.travels)
                column(title: "Never leaves this Mac", symbol: "minus.circle.fill", tint: .secondary, items: Self.stays)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What an encrypted archive contains")
    }

    private func column(title: String, symbol: String, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol).font(.caption2).foregroundStyle(tint)
                    Text(item).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
