import AgentToolingCore
import Foundation
import Observation

/// Earlier states of this workspace, and returning to one of them.
///
/// Choosing a point never changes anything on its own: the preview is read, and
/// restoring is a separate confirmed step that commits the old contents as a
/// new version on top of the current one. Nothing in any app is touched — a
/// restore changes what this workspace asks for, and Install remains the only
/// thing that writes into a client.
@MainActor @Observable
final class WorkspaceHistorySession {
    private(set) var points: [WorkspaceRestorePoint] = []
    private(set) var selectedID: WorkspaceObjectID?
    private(set) var preview: WorkspaceRestorePreview?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var lastRestoredID: WorkspaceObjectID?

    private let store: WorkspaceRevisionStore
    private let library: WorkspaceLibrarySession
    private let writerID: WorkspaceObjectID
    private let access: WorkspaceLibraryAccess

    init(
        store: WorkspaceRevisionStore,
        library: WorkspaceLibrarySession,
        writerID: WorkspaceObjectID,
        access: WorkspaceLibraryAccess
    ) {
        self.store = store
        self.library = library
        self.writerID = writerID
        self.access = access
    }

    /// A read-only workspace can look through its history but not rewrite it.
    var canRestore: Bool {
        guard access == .writable, let selectedID, !isBusy else { return false }
        return points.first { $0.revisionID == selectedID }?.isCurrent == false
    }

    var selected: WorkspaceRestorePoint? {
        points.first { $0.revisionID == selectedID }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            points = try WorkspaceRestorePoints.available(in: store, limit: 40)
            errorMessage = nil
            // A selection that history no longer offers is dropped rather than
            // left pointing at nothing.
            if let selectedID, !points.contains(where: { $0.revisionID == selectedID }) {
                self.selectedID = nil
                preview = nil
            }
            if let selectedID { loadPreview(selectedID) }
        } catch {
            points = []
            preview = nil
            errorMessage = "This workspace's earlier versions could not be read on this Mac."
        }
    }

    func select(_ id: WorkspaceObjectID?) {
        selectedID = id
        guard let id else { preview = nil; return }
        loadPreview(id)
    }

    /// Returns the workspace to the selected point.
    ///
    /// The version the preview was read against is what the restore is decided
    /// against, so a change that arrived in between is refused rather than
    /// quietly overwritten.
    func restore() async {
        guard canRestore, let selectedID,
              let head = points.first(where: \.isCurrent)?.revisionID else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try WorkspaceRestorePoints.restore(selectedID, in: store,
                                                   expectedRevisionID: head, writerID: writerID)
            lastRestoredID = selectedID
            self.selectedID = nil
            preview = nil
        } catch WorkspaceRevisionStoreError.staleRevision {
            errorMessage = "This workspace changed while you were looking. Nothing was restored — check the versions again."
        } catch {
            errorMessage = "That version could not be restored. Nothing was changed."
        }
        await library.refresh()
        do { points = try WorkspaceRestorePoints.available(in: store, limit: 40) } catch { points = [] }
    }

    private func loadPreview(_ id: WorkspaceObjectID) {
        do {
            preview = try WorkspaceRestorePoints.preview(restoring: id, in: store)
            if preview == nil {
                errorMessage = "That version is no longer in this workspace's history."
            }
        } catch {
            preview = nil
            errorMessage = "That version could not be read on this Mac."
        }
    }
}
