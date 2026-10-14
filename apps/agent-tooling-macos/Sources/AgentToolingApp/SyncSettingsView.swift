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
                        .primaryActionStyle()
                        .disabled(session.isBusy)
                }
            }
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    if let message = session.errorMessage {
                        AttentionBanner(title: "Sync needs attention", message: message)
                    }
                    if let recovery = session.recoveryPhrase { recoveryCard(recovery) }
                    if let enrollment = session.enrollment { connectedCard(enrollment) } else { setupCard }
                    if !session.conflicts.isEmpty { conflictsCard }
                    if session.isConnected || session.devices.count > 1 { macsCard }
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
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(
                    "Agent Tooling shares your library and where each tool belongs. Through a repository it also carries the files of skills you wrote here, so another Mac can install them. Your app settings and anything else on this Mac are not shared."
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
            .padding(Space.xl)
        }
    }

    private var gitSetup: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("A repository is not encrypted storage. Anyone with access to it can read what is published there.")
                .font(AgentFont.body).foregroundStyle(.secondary)
            LabeledContent("Repository") {
                TextField("https://github.com/you/workspace.git", text: $remote)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
            }
            HStack(spacing: Space.lg) {
                Button("Choose folder on this Mac…") { chooseCheckout() }
                Text(checkout?.path ?? "No folder chosen").foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Connect") {
                guard let checkout else { return }
                Task {
                    await session.connect(remote: remote.trimmingCharacters(in: .whitespacesAndNewlines), checkout: checkout)
                }
            }
            .primaryActionStyle()
            .disabled(session.isBusy || checkout == nil || remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var folderSetup: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(
                "Point this at a folder iCloud Drive, Dropbox or a network share already keeps in step between your Macs. What lands there is sealed: the service moving it cannot read your library."
            )
            .font(AgentFont.body).foregroundStyle(.secondary)
            SyncScopePanel()
            HStack(spacing: Space.lg) {
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
            .primaryActionStyle()
            .disabled(session.isBusy || folder == nil)
        }
    }

    /// Shown once. There is nowhere else this app will show it again, so the
    /// reminder to move it into a password manager sits right beside it.
    private func recoveryCard(_ phrase: String) -> some View {
        TitledCard("Write this down now") {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text(phrase)
                    .font(AgentFont.monoBody)
                    .textSelection(.enabled)
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AgentTheme.fillSubtle, in: RoundedRectangle.control)
                Text(
                    "This is the only way to open that folder from another Mac. Agent Tooling will not show it again, and cannot recover it for you."
                )
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                Text("Copy it to a password manager before you need it on another Mac.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(recoveryCopied ? "Copied" : "Copy") { copyRecoveryPhrase(phrase) }
                        .secondaryActionStyle()
                        .disabled(recoveryCopied)
                    Button("I have written it down") { session.dismissRecoveryPhrase() }
                        .primaryActionStyle()
                }
            }
            .padding(Space.xl)
        }
    }

    private func connectedCard(_ enrollment: WorkspaceSyncEnrollment) -> some View {
        TitledCard("Connected on this Mac") {
            VStack(alignment: .leading, spacing: 0) {
                if enrollment.kind == .git {
                    InfoRow("Repository", detail: nil) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                    } trailing: {
                        Text(enrollment.remote).textSelection(.enabled).lineLimit(1)
                    }
                    Hairline()
                    InfoRow("Branch", detail: nil) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                    } trailing: {
                        Text(enrollment.branch)
                    }
                    Hairline()
                    InfoRow("Folder on this Mac", detail: nil) {
                        Image(systemName: "folder").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                    } trailing: {
                        LocationText(path: enrollment.checkoutPath)
                    }
                } else {
                    InfoRow("Shared folder", detail: "Sealed. The service moving it cannot read your library.") {
                        Image(systemName: "lock.folder").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                    } trailing: {
                        LocationText(path: enrollment.checkoutPath)
                    }
                    Hairline()
                    SyncScopePanel()
                }
                Hairline()
                InfoRow("Sync on its own while the app is open", detail: session.scheduleText) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                } trailing: {
                    Toggle(
                        "Sync on its own while the app is open",
                        isOn: Binding(get: { session.isAutomatic }, set: { session.setAutomatic($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(session.isBusy)
                }
                Hairline()
                Text(
                    enrollment.kind == .git
                        ? "Syncing shares your library — including the files of skills you wrote here — and where each tool belongs. Installing on each Mac is that Mac's own step, by its own Updates policy."
                        : "Syncing shares what your library holds and where each tool belongs. The sealed folder carries no skill files; a skill you wrote here reaches another Mac only if it also follows a repository."
                )
                .font(AgentFont.body).foregroundStyle(.secondary)
                .padding(Space.xl)
                Hairline()
                InfoRow(
                    "Disconnect this Mac",
                    detail: enrollment.kind == .git
                        ? "The repository and its history are left alone."
                        : "The folder is left alone, and stays readable by any Mac that still has the phrase."
                ) {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
                } trailing: {
                    Button("Disconnect") { session.disconnect() }
                        .secondaryActionStyle()
                        .disabled(session.isBusy)
                }
            }
        }
    }

    @State private var renaming: DeviceRecord?
    @State private var renameText = ""

    /// Every Mac in the workspace: this one first. Rename, take-shared, retire.
    private var macsCard: some View {
        let devices = session.devices.filter { !$0.isRetired }
        let retired = session.devices.filter(\.isRetired)
        return TitledCard("Macs", count: "\(devices.count)") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(devices.sorted { lhs, rhs in
                    if lhs.id == session.deviceID { return true }
                    if rhs.id == session.deviceID { return false }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }) { device in
                    macRow(device)
                    Hairline(indent: Hairline.afterLeading(Size.glyphSlot))
                }
                if !retired.isEmpty {
                    Text("Retired: \(retired.map(\.name).formatted(.list(type: .and))). Kept for history; they take nothing.")
                        .font(AgentFont.caption).foregroundStyle(.tertiary).wrapsLines()
                        .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
                    Hairline()
                }
                Text("Every Mac keeps its own apps. Turning off shared assignments makes a Mac opt-in: it gets only what names it, and nothing on it is marked missing.")
                    .font(AgentFont.caption).foregroundStyle(.tertiary).wrapsLines()
                    .padding(.horizontal, Space.xl).padding(.vertical, Space.md)
            }
        }
        .sheet(item: $renaming) { device in
            renameSheet(device)
        }
    }

    private func macRow(_ device: DeviceRecord) -> some View {
        let isThis = device.id == session.deviceID
        let status = session.status(of: device.id)
        return InfoRow(
            isThis ? "\(device.name) (this Mac)" : device.name,
            detail: macDetail(device, status: status)
        ) {
            Image(systemName: isThis ? "desktopcomputer" : "laptopcomputer").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
        } trailing: {
            HStack(spacing: Space.md) {
                Toggle("Takes shared assignments", isOn: Binding(
                    get: { device.receivesSharedAssignments },
                    set: { value in Task { await session.setReceivesSharedAssignments(value, for: device.id) } }))
                    .labelsHidden().toggleStyle(.switch).disabled(session.isBusy)
                    .help("Off: this Mac gets only items assigned to it by name.")
                Menu {
                    Button("Rename…") { renameText = device.name; renaming = device }
                    if !isThis {
                        Button("Retire this Mac", role: .destructive) { Task { await session.retireDevice(device.id) } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button).buttonStyle(.glass).disabled(session.isBusy)
            }
        }
    }

    private func macDetail(_ device: DeviceRecord, status: PublishedDeviceStatus?) -> String {
        var parts: [String] = []
        if device.id == session.deviceID {
            parts.append(session.lastSynced.map { "Synced \(SnapshotTime.compact($0))" } ?? "Not synced yet")
        } else if let status {
            parts.append("Published \(SnapshotTime.compact(status.publishedAt))")
            let installed = status.apps.filter(\.installed)
            if !installed.isEmpty {
                parts.append(installed.map { "\($0.surface.displayName) \($0.skillCount) skills" }.joined(separator: ", "))
            }
            if !status.pending.isEmpty { parts.append("\(status.pending.count) pending") }
        } else if let seen = device.lastSeenAt {
            parts.append("Last seen \(SnapshotTime.compact(seen))")
        } else {
            parts.append("Not seen yet")
        }
        if !device.receivesSharedAssignments { parts.append("Takes only what names it") }
        return parts.joined(separator: " · ")
    }

    private func renameSheet(_ device: DeviceRecord) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Rename \(device.name)").font(AgentFont.title)
            TextField("Name", text: $renameText).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }.secondaryActionStyle().keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let name = renameText
                    renaming = nil
                    Task { await session.renameDevice(device.id, to: name) }
                }
                .primaryActionStyle().keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.xxl)
        .sheetSize(SheetSize.small)
    }

    private var conflictsCard: some View {
        TitledCard("Decisions to make") {
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    "Two Macs changed the same thing differently. Nothing was changed here; open each item and choose which result to keep."
                )
                .font(AgentFont.body).foregroundStyle(.secondary)
                .padding(Space.xl)
                ForEach(Array(session.conflicts.enumerated()), id: \.offset) { index, conflict in
                    Hairline()
                    VStack(alignment: .leading, spacing: Space.md) {
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
                            .labelsHidden().pickerStyle(.segmented).controlSize(.regular).fixedSize()
                            .disabled(session.isBusy)
                        } else {
                            Text("This one cannot be settled by picking a Mac. Change what each item asks for, then sync again.")
                                .font(AgentFont.body).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Space.xl)
                }
                Hairline()
                HStack {
                    Button("Apply decisions") { Task { await session.applyDecisions() } }
                        .primaryActionStyle()
                        .disabled(session.isBusy || session.hasUndecidedConflicts)
                    Text(
                        session.hasUndecidedConflicts
                            ? "Decide every item above before applying."
                            : "Your decisions are applied against the newest shared version."
                    )
                    .font(AgentFont.body).foregroundStyle(.secondary)
                }
                .padding(Space.xl)
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
        case .subscriptionOwnerCollision: "The same skill linked to a repository twice"
        case .subscriptionContentMismatch: "Linked on one Mac, edited on another"
        case .catalogSource: "Two different catalogs recorded as one"
        case .projectField: "Two different project names"
        case .deviceField: "Two different settings for one Mac"
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
        "Your library's records: skills, plugins, servers, presets, projects",
        "Where each tool is assigned, to which apps and which Macs",
        "The names of the Macs sharing the library",
    ]

    private static let stays = [
        "The encryption key — Keychain only",
        "Skill files — a sealed folder carries records only; a repository carries the files too",
        "This Mac's own observed state and receipts",
        "Project folders and local sources",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("What an archive contains").font(AgentFont.bodyMedium)
            HStack(alignment: .top, spacing: Space.xxxl) {
                column(title: "Travels to another Mac", symbol: "checkmark.circle.fill", tint: AgentTheme.ok, items: Self.travels)
                column(title: "Never leaves this Mac", symbol: "minus.circle.fill", tint: .secondary, items: Self.stays)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What an encrypted archive contains")
    }

    private func column(title: String, symbol: String, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(AgentFont.captionSemibold).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Image(systemName: symbol).font(AgentFont.micro).foregroundStyle(tint)
                    Text(item).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
