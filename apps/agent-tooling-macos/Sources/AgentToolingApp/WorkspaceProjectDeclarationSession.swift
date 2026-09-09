import AgentToolingCore
import Foundation
import Observation

/// Writing a project's own declaration and lock into its folder.
///
/// Two files and nothing else. The declaration says what this project asks for;
/// the lock pins what that resolved to, so a later checkout reproduces the same
/// bytes. Both are meant to be committed, so neither carries a path from this
/// Mac, a device identity, an observation time or a credential.
///
/// Only items whose content this workspace actually pinned reach the lock. An
/// item the workspace holds without an immutable upstream revision appears in
/// the declaration — it is genuinely something this project asks for — and is
/// named as unlocked, because writing a lock line that cannot restore the same
/// bytes would be the one thing a lock must not do.
@MainActor @Observable
final class WorkspaceProjectDeclarationSession {
    struct Preview: Sendable {
        let declaration: WorkspaceProjectDeclaration
        let lock: WorkspaceProjectLock?
        /// Named, not dropped: these are asked for but cannot be pinned.
        let unlocked: [String]
    }

    /// What a declaration already committed in the folder asks for, against
    /// what this workspace holds. Read-only: answering "what does this project
    /// want, and what do I have" is a different act from getting it.
    private(set) var committed: WorkspaceProjectDeclarationReconciliation.Result?
    private(set) var committedMessage: String?
    private(set) var preview: Preview?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var writtenPaths: [String] = []

    private let library: WorkspaceLibrarySession

    init(library: WorkspaceLibrarySession) {
        self.library = library
    }

    var canWrite: Bool { library.access == .writable }

    /// Reads a declaration the project already carries and compares it with
    /// this workspace. Nothing is written and nothing is installed.
    func readCommitted(projectRoot: URL) {
        guard !isBusy, let document = library.state?.snapshot.document else { return }
        committed = nil
        committedMessage = nil
        do {
            let store = try WorkspaceProjectDeclarationStore(
                projectRoot: projectRoot.standardizedFileURL)
            guard let declaration = try store.readDeclaration() else {
                committedMessage = "This project carries no Agent Tooling declaration yet."
                return
            }
            committed = WorkspaceProjectDeclarationReconciliation.reconcile(
                declaration: declaration, lock: try store.readLock(), against: document)
        } catch WorkspaceProjectDeclarationError.unsupportedFormat {
            // Reading nothing would look like the project asks for nothing.
            committedMessage = "This project's declaration is in a form this version cannot read, so nothing is compared against it."
        } catch {
            committedMessage = "This project's declaration could not be read on this Mac."
        }
    }

    /// Builds both files without writing anything.
    func prepare(projectID: ArtifactID) {
        guard !isBusy, let snapshot = library.state?.snapshot else { return }
        errorMessage = nil
        writtenPaths = []
        preview = nil
        let document = snapshot.document
        let wanted = Set(document.assignments
            .filter { $0.destination.logicalProjectID == projectID && $0.desiredPresence }
            .map(\.artifactID))
        let subscriptions = Dictionary(document.subscriptions.map { ($0.artifactID, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let sources = Dictionary(document.sources.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })

        var declared: [WorkspaceProjectDeclaration.Entry] = []
        var locked: [WorkspaceProjectLock.Entry] = []
        var unlocked: [String] = []
        for artifact in document.artifacts
        where wanted.contains(artifact.identity.id) && artifact.identity.parentPackageID == nil {
            let name = artifact.declaredName ?? artifact.identity.displayName
            let subscription = subscriptions[artifact.identity.id]
            let repository = subscription.flatMap { sources[$0.sourceID]?.repositoryURL }
            declared.append(.init(
                name: name, kind: artifact.identity.kind, repositoryURL: repository,
                requestedRef: subscription?.lock.requestedRef,
                packageRelativePath: subscription?.lock.packageRelativePath))
            guard let subscription else {
                unlocked.append(name)
                continue
            }
            let entry = WorkspaceProjectLock.Entry(
                name: name, kind: artifact.identity.kind, repositoryURL: repository,
                requestedRef: subscription.lock.requestedRef,
                revision: subscription.lock.approvedRevision,
                contentDigest: subscription.lock.approvedContent,
                packageRelativePath: subscription.lock.packageRelativePath)
            // The lock's own rule decides, not this: an entry it refuses is one
            // that could not restore the same bytes.
            if (try? WorkspaceProjectLock(entries: [entry])) != nil {
                locked.append(entry)
            } else {
                unlocked.append(name)
            }
        }

        do {
            preview = .init(
                declaration: try .init(entries: declared),
                lock: locked.isEmpty ? nil : try .init(entries: locked),
                unlocked: unlocked.sorted())
        } catch {
            errorMessage = "This project's declaration could not be prepared. Nothing was written."
        }
    }

    func discard() {
        guard !isBusy else { return }
        preview = nil
        errorMessage = nil
        writtenPaths = []
        committed = nil
        committedMessage = nil
    }

    /// Writes both files into the project folder.
    func write(to projectRoot: URL) async {
        guard canWrite, !isBusy, let preview else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let store = try WorkspaceProjectDeclarationStore(
                projectRoot: projectRoot.standardizedFileURL)
            try store.write(declaration: preview.declaration, lock: preview.lock)
            writtenPaths = [store.declarationURL.path] + (preview.lock == nil ? [] : [store.lockURL.path])
        } catch WorkspaceProjectDeclarationError.foreignFile {
            errorMessage = "There is already a file with that name that Agent Tooling did not write. It was left alone and nothing was written."
        } catch WorkspaceProjectDeclarationError.invalidRoot {
            errorMessage = "Choose a folder on this Mac to write into."
        } catch {
            errorMessage = "Those files could not be written. Nothing was changed."
        }
    }
}
