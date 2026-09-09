import Foundation

/// The exact legacy workspace selected for a reviewed migration. The caller
/// supplies this location to the versioned migration flow; entering review
/// itself does not create, copy, or modify either location.
public struct WorkspaceMigrationLegacyLocation: Sendable, Equatable {
    public let legacyRoot: URL
    public let homeRoot: URL

    public init(legacyRoot: URL, homeRoot: URL) {
        self.legacyRoot = legacyRoot
        self.homeRoot = homeRoot
    }
}

private enum WorkspaceMigrationReviewGateError: LocalizedError {
    case active

    var errorDescription: String? {
        "Migration review is active. Finish or cancel it before changing this workspace."
    }
}

extension AppModel {
    /// Starts an exclusive, review-only handoff to the versioned workspace
    /// migration flow. Existing work is never interrupted: callers must wait
    /// for it to complete and then begin review from a quiet legacy workspace.
    public func beginWorkspaceMigrationReview() -> WorkspaceMigrationLegacyLocation? {
        guard !isWorkspaceMigrationReviewActive else {
            presentError("Migration review is already active.")
            return nil
        }
        guard !isBusy, pendingPlan == nil else {
            presentError("Finish the current operation and any pending review before starting migration review.")
            return nil
        }
        isWorkspaceMigrationReviewActive = true
        return WorkspaceMigrationLegacyLocation(legacyRoot: store.rootURL, homeRoot: homeURL)
    }

    /// Cancels the exclusive review state without changing the legacy
    /// workspace. The versioned review flow owns any separate prepared record.
    @discardableResult
    public func endWorkspaceMigrationReview() -> Bool {
        do {
            guard try WorkspaceAuthorityStore(legacyRoot: store.rootURL).read()?.choice != .versioned else {
                presentError("The central library is now active. Reopen the workspace to continue.")
                return false
            }
            isWorkspaceMigrationReviewActive = false
            return true
        } catch {
            presentError("The saved workspace choice could not be verified. Reopen the workspace before changing it.")
            return false
        }
    }

    func requireWorkspaceMigrationReviewInactive() throws {
        guard !isWorkspaceMigrationReviewActive else {
            throw WorkspaceMigrationReviewGateError.active
        }
    }
}
