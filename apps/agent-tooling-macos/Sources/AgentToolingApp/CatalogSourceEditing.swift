import AgentToolingCore
import AppKit
import SwiftUI

/// Adding a catalog to Discover's list, and taking one off it.
///
/// A catalog source is where this app looks, not what it holds. Adding one
/// reads nothing, fetches nothing and installs nothing: the next refresh looks
/// at the folder, every listing it finds still has to be added to the library,
/// and every install still goes through the app that owns it.
///
/// Removing one is the same act in reverse. Discover stops listing what the
/// catalog publishes; nothing that was ever installed from it is touched, and
/// nothing stops the same folder being added again — no record is kept saying a
/// person once said no.
@MainActor @Observable
final class WorkspaceCatalogSourceSession {
    private(set) var isBusy = false
    /// The refusal a screen shows verbatim. Kept here rather than on the
    /// catalog session so a refusal about one folder never appears under the
    /// heading that says which catalogs failed to answer.
    private(set) var errorMessage: String?

    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let catalogs: WorkspaceMarketplaceSession

    init(
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        catalogs: WorkspaceMarketplaceSession
    ) {
        self.service = service
        self.library = library
        self.catalogs = catalogs
    }

    convenience init(workspace: WorkspaceLaunch.Workspace, catalogs: WorkspaceMarketplaceSession) {
        self.init(service: workspace.service, library: workspace.library, catalogs: catalogs)
    }

    var canWrite: Bool { library.access == .writable }

    func clearError() { errorMessage = nil }

    /// Records one catalog. True when it landed.
    @discardableResult
    func add(_ draft: CatalogSourceDraft) async -> Bool {
        await perform {
            try WorkspaceCatalogSourceCommand(
                expectedRevisionID: $0,
                adding: .init(
                    name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), kind: draft.kind,
                    remoteLocation: draft.remoteLocation),
                localLocation: draft.localLocation)
        }
    }

    /// Takes one recorded catalog off the list. True when it landed.
    @discardableResult
    func remove(_ sourceID: UUID) async -> Bool {
        await perform { .init(expectedRevisionID: $0, removing: WorkspaceObjectID(sourceID)) }
    }

    /// One command, against the head this workspace is actually at.
    ///
    /// The list is re-read from the store afterwards rather than re-fetched:
    /// what changed is where this app will look, and no catalog was asked
    /// anything, so claiming a fresh answer from one would be an invention.
    private func perform(
        _ build: (WorkspaceObjectID) throws -> WorkspaceCatalogSourceCommand
    ) async -> Bool {
        guard canWrite, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                errorMessage = "This workspace could not be read. Nothing was changed."
                return false
            }
            _ = try await service.changeCatalogSource(try build(head))
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
        catalogs.reloadSources()
        // The head moved, so the library is read again rather than left
        // holding an older one.
        await library.refresh()
        return true
    }

    /// The command's own words wherever it has them. A refusal a person cannot
    /// read is a disabled button with extra steps.
    private static func message(for error: any Error) -> String {
        if let refusal = error as? WorkspaceCatalogSourceError { return refusal.localizedDescription }
        if let validation = error as? WorkspaceDomainValidationError,
            validation == .invalidField("catalog source name")
        {
            return "Give this catalog a name."
        }
        if error is WorkspaceRevisionStoreError {
            return "This workspace changed while that was being entered. Look at the list again and try once more."
        }
        return "That catalog could not be recorded. Nothing was changed."
    }
}

/// What somebody filled in, before any of it is a record.
struct CatalogSourceDraft: Equatable {
    var name: String
    var kind: SourceKind
    /// The repository this checkout came from, when they named one. Credential
    /// free, because it travels to every other Mac.
    var remoteLocation: String?
    /// Where the folder is on this Mac. Never portable.
    var localLocation: String?
}

/// The toolbar's "Add source…".
///
/// It owns its own sheet so that Discover keeps no state for a panel it only
/// presents, and so the two controls that write a catalog source cannot end up
/// reporting each other's refusals.
struct AddCatalogSourceButton: View {
    let workspace: WorkspaceLaunch.Workspace
    let catalogs: WorkspaceMarketplaceSession
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            Label("Add source…", systemImage: "plus")
        }
        .buttonStyle(.glass)
        .disabled(!canWrite)
        .help(hint)
        .sheet(isPresented: $presented) {
            AddCatalogSourceSheet(workspace: workspace, catalogs: catalogs)
        }
    }

    private var canWrite: Bool { workspace.library.access == .writable }

    private var hint: String {
        canWrite
            ? "Record a folder of packages or a Git checkout for Discover to read"
            : "This workspace is open for reading only."
    }
}

/// Choosing a catalog to record.
///
/// Two kinds, because two kinds are what this build can actually read: a folder
/// of portable packages, and a Git checkout of one on this Mac. The catalogs
/// your apps publish are already on the list and are read through those apps.
struct AddCatalogSourceSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    let catalogs: WorkspaceMarketplaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var session: WorkspaceCatalogSourceSession
    @State private var name = ""
    @State private var kind: SourceKind = .localFolder
    @State private var folder: String?
    @State private var repository = ""

    init(workspace: WorkspaceLaunch.Workspace, catalogs: WorkspaceMarketplaceSession) {
        self.workspace = workspace
        self.catalogs = catalogs
        _session = State(initialValue: .init(workspace: workspace, catalogs: catalogs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add a catalog").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Discover reads the catalog and lists what it publishes. Adding one records where to look — nothing is fetched now, nothing is installed, and each package is still added to your library one at a time."
                )
                .foregroundStyle(.secondary)

                if let message = session.errorMessage {
                    AttentionBanner(title: "That catalog was not recorded", message: message)
                }

                Picker("Kind", selection: $kind) {
                    Text("Folder of packages").tag(SourceKind.localFolder)
                    Text("Git checkout").tag(SourceKind.gitRepository)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Catalog kind")

                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Name") {
                        TextField("Team catalog", text: $name)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    }
                    LabeledContent("Folder on this Mac") {
                        HStack(spacing: 10) {
                            Text(folder ?? "None chosen")
                                .foregroundStyle(folder == nil ? .secondary : .primary)
                                .textSelection(.enabled).lineLimit(2)
                            Button("Choose…") { choose() }.disabled(session.isBusy)
                        }
                    }
                    if kind == .gitRepository {
                        LabeledContent("Repository") {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("https://example.com/team/catalog", text: $repository)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                                Text("Optional, and shared with your other Macs. Leave out any user name or token.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
                .standardPanel(cornerRadius: 12)

                Text(
                    "The folder stays where it is and is only ever read. Its path is this Mac's own — your other Macs see the catalog and bind it to their own copy."
                )
                .font(.callout).foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Spacer()
                    Button("Add catalog") { commit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdd)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 460)
        .background(AgentTheme.contentBackground)
    }

    private var canAdd: Bool {
        !session.isBusy && session.canWrite && folder != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draft: CatalogSourceDraft {
        let address = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            name: name, kind: kind,
            remoteLocation: kind == .gitRepository && !address.isEmpty ? address : nil,
            localLocation: folder)
    }

    private func commit() {
        Task {
            if await session.add(draft) { dismiss() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.clearError()
        folder = url.standardizedFileURL.path
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = url.standardizedFileURL.lastPathComponent
        }
    }
}

/// The per-source Remove on Discover's Sources list.
///
/// Shown only on the catalogs this workspace actually recorded. The rows every
/// build lists are references rather than records — nobody added them, so there
/// is nothing there to take away.
///
/// It confirms first, and says what removing does and does not do, because the
/// two are easy to confuse: the list stops showing what this catalog publishes,
/// and everything ever installed from it stays exactly where it is.
struct RemoveCatalogSourceButton: View {
    let workspace: WorkspaceLaunch.Workspace
    let catalogs: WorkspaceMarketplaceSession
    let source: ToolingSource
    @State private var session: WorkspaceCatalogSourceSession
    @State private var confirming = false

    init(workspace: WorkspaceLaunch.Workspace, catalogs: WorkspaceMarketplaceSession, source: ToolingSource) {
        self.workspace = workspace
        self.catalogs = catalogs
        self.source = source
        _session = State(initialValue: .init(workspace: workspace, catalogs: catalogs))
    }

    var body: some View {
        Button {
            session.clearError()
            confirming = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(!session.canWrite || session.isBusy)
        .help(hint)
        .accessibilityLabel("Remove \(source.name)")
        .popover(isPresented: $confirming, arrowEdge: .bottom) {
            RemoveCatalogSourceConfirmation(session: session, source: source) { confirming = false }
        }
    }

    private var hint: String {
        session.canWrite
            ? "Stop listing what \(source.name) publishes"
            : "This workspace is open for reading only."
    }
}

/// What removing a catalog does, said before it is done, and what it refused
/// when it was.
///
/// The two are easy to confuse, so both are on screen: the list stops showing
/// what this catalog publishes, and everything ever installed from it stays
/// exactly where it is.
struct RemoveCatalogSourceConfirmation: View {
    let session: WorkspaceCatalogSourceSession
    let source: ToolingSource
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(source.name)?").font(.callout.weight(.semibold))
            Text(session.errorMessage ?? Self.consequence)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Keep") { close() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    Task {
                        if await session.remove(source.id) { close() }
                    }
                }
                .disabled(session.isBusy)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    static let consequence =
        "Discover stops listing what it publishes. Nothing installed from it is removed, and you can add the same folder again whenever you like."
}
