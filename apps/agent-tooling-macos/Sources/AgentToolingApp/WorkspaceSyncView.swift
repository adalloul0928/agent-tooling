import AgentToolingCore
import AppKit
import SwiftUI

/// Connecting this Mac to a shared workspace repository, and what the last sync
/// actually did. Conflicts are shown as decisions to make, never resolved here
/// on the person's behalf.
struct WorkspaceSyncView: View {
    let session: WorkspaceSyncSession
    @State private var remote = ""
    @State private var checkout: URL?
    @State private var kind: WorkspaceSyncTransportKind = .git
    @State private var folder: URL?
    @State private var phrase = ""

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Sync", context: session.statusText) {
                if session.isConnected {
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await session.sync() }
                    }
                    .buttonStyle(.glassProminent).tint(AgentTheme.selection)
                    .disabled(session.isBusy)
                }
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Sync needs attention", message: message)
                    }
                    if let recovery = session.recoveryPhrase { phraseCard(recovery) }
                    if let enrollment = session.enrollment {
                        connected(enrollment)
                    } else {
                        setup
                    }
                    if !session.conflicts.isEmpty { conflictList }
                }
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
        .frame(minWidth: 720, minHeight: 480)
        .task {
            session.load()
            // The loop wakes often and syncs rarely: every wake-up asks the
            // scheduler, which spaces real passes fifteen minutes apart and
            // stops them entirely while a conflict is undecided. It runs only
            // while this view is on screen, so closing the app ends it.
            while !Task.isCancelled {
                await session.runScheduledPass()
                do { try await Task.sleep(for: WorkspaceSyncSession.checkInterval) }
                catch { return }
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use the same setup on more than one Mac").font(.title3.weight(.semibold))
            Text("Agent Tooling keeps one file describing your library and where each tool belongs. Your skills' own repositories, your app settings, and anything else on this Mac are not shared.")
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
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private var gitSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A repository is not encrypted storage. Anyone with access to it can read what is published there.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Repository") {
                TextField("https://github.com/you/workspace.git", text: $remote)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 12) {
                Button("Choose folder on this Mac…") { chooseCheckout() }
                Text(checkout?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Connect") {
                guard let checkout else { return }
                Task { await session.connect(remote: remote.trimmingCharacters(in: .whitespacesAndNewlines),
                                             checkout: checkout) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isBusy || checkout == nil
                || remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var folderSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Point this at a folder iCloud Drive, Dropbox or a network share already keeps in step between your Macs. What lands there is sealed: the service moving it cannot read your library.")
                .font(.callout).foregroundStyle(.secondary)
            Text("The key that opens it is kept on this Mac, readable by your account. This protects your library from the sync service, not from someone who can already read this Mac.")
                .font(.callout).foregroundStyle(.secondary)
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

    /// Shown once. There is nowhere else this app will show it again.
    private func phraseCard(_ phrase: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Write this down now", systemImage: "key")
                .font(.title3.weight(.semibold))
            Text(phrase)
                .font(.system(size: 15, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentTheme.contentBackground, in: RoundedRectangle(cornerRadius: 8))
            Text("This is the only way to open that folder from another Mac. Agent Tooling will not show it again, and cannot recover it for you.")
                .foregroundStyle(.secondary)
            Button("I have written it down") { session.dismissRecoveryPhrase() }
                .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private func connected(_ enrollment: WorkspaceSyncEnrollment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connected on this Mac").font(.title3.weight(.semibold))
            if enrollment.kind == .git {
                LabeledContent("Repository") {
                    Text(enrollment.remote).textSelection(.enabled).lineLimit(1)
                }
                LabeledContent("Branch") { Text(enrollment.branch) }
                LabeledContent("Folder on this Mac") {
                    Text(enrollment.checkoutPath).textSelection(.enabled).lineLimit(1)
                }
            } else {
                LabeledContent("Shared folder") {
                    Text(enrollment.checkoutPath).textSelection(.enabled).lineLimit(2)
                }
                Text("Sealed in that folder. The service moving it cannot read your library.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Sync on its own while the app is open", isOn: Binding(
                get: { session.isAutomatic },
                set: { session.setAutomatic($0) }
            ))
            .disabled(session.isBusy)
            if let schedule = session.scheduleText {
                Text(schedule).font(.callout).foregroundStyle(.secondary)
            }
            Text("Syncing shares what your library holds and where each tool belongs. It does not install or remove anything in your apps; that stays a separate reviewed step.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Disconnect this Mac") { session.disconnect() }
                    .disabled(session.isBusy)
                Text(enrollment.kind == .git
                     ? "The repository and its history are left alone."
                     : "The folder is left alone, and stays readable by any Mac that still has the phrase.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
    }

    private var conflictList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decisions to make").font(.title3.weight(.semibold))
            Text("Two Macs changed the same thing differently. Nothing was changed here; open each item and choose which result to keep.")
                .foregroundStyle(.secondary)
            ForEach(Array(session.conflicts.enumerated()), id: \.offset) { index, conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(title(conflict.kind)).fontWeight(.medium)
                    Text(conflict.detail).foregroundStyle(.secondary)
                    if session.canDecide(index) {
                        Picker("Keep", selection: Binding(
                            get: { session.choices[index] },
                            set: { if let value = $0 { session.choose(value, at: index) } }
                        )) {
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
                .padding(.vertical, 8)
                Divider()
            }
            HStack {
                Button("Apply decisions") { Task { await session.applyDecisions() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy || session.hasUndecidedConflicts)
                Text(session.hasUndecidedConflicts
                     ? "Decide every item above before applying."
                     : "Your decisions are applied against the newest shared version.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .standardPanel(cornerRadius: 14)
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
        case .projectField: "Two different project names"
        case .unsupportedVersion: "A newer format than this app can read"
        case .invalidResult: "The combined setup did not pass its own checks"
        }
    }
}
