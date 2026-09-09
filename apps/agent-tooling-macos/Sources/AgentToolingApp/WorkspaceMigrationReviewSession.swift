import AgentToolingCore
import Observation

/// App-local presentation state for a migration that was explicitly located by
/// the pilot owner. It never discovers a versioned store or creates migration
/// inputs; Core verifies every transition against the durable journal.
@MainActor @Observable
final class WorkspaceMigrationReviewSession {
    let location: WorkspaceMigrationReviewLocation
    private let service: any WorkspaceMigrationReviewServing

    private(set) var state: WorkspaceMigrationReviewState?
    private(set) var pendingSelection: WorkspaceAuthoritySelection?
    private(set) var committedSelection: WorkspaceAuthoritySelection?
    private(set) var initializedEntry: WorkspaceMigrationJournalEntry?
    private(set) var errorMessage: String?
    private(set) var isBusy = false

    init(service: any WorkspaceMigrationReviewServing, location: WorkspaceMigrationReviewLocation) {
        self.service = service
        self.location = location
    }

    func refresh() async {
        await perform(clearPending: true) {
            let next = try await self.service.state()
            self.state = next
            if next.journalEntry.phase == .initialized { self.initializedEntry = nil }
        }
    }

    func initializeReviewed() async {
        guard let state, state.journalEntry.phase == .prepared else { return }
        let reviewedRecord = state.journalEntry.record
        guard !isBusy else { return }
        isBusy = true
        pendingSelection = nil
        initializedEntry = nil
        errorMessage = nil
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            let receipt = try await service.initializeReviewed(record: reviewedRecord)
            // Persist the durable result before any cancellation point or read.
            initializedEntry = receipt
            do {
                self.state = try await service.state()
            } catch is CancellationError {
                errorMessage = "The migration was initialized. Refresh this review before continuing."
            } catch {
                errorMessage = "The migration was initialized, but this review could not refresh."
            }
        } catch is CancellationError {
        } catch {
            errorMessage = "The reviewed migration could not be initialized. Refresh and review it again."
        }
    }

    func prepareActivation() async {
        await prepare {
            try await self.service.prepareActivation()
        }
    }

    func prepareRollback() async {
        await prepare {
            try await self.service.prepareRollback()
        }
    }

    func applyPendingSelection() async {
        guard let pendingSelection else { return }
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            let receipt = try await service.apply(selection: pendingSelection)
            // Persist the durable result before any cancellation point or read.
            guard receipt == pendingSelection else {
                errorMessage = "The saved workspace choice did not match the reviewed choice. Refresh and review it again."
                self.pendingSelection = nil
                return
            }
            committedSelection = receipt
            self.pendingSelection = nil
            do {
                state = try await service.state()
            } catch is CancellationError {
                errorMessage = "The workspace choice was saved. Refresh this review before continuing."
            } catch {
                errorMessage = "The workspace choice was saved, but this review could not refresh."
            }
        } catch is CancellationError {
            // Retain the exact pending selection so an interrupted confirmation
            // can be retried without preparing a different choice.
        } catch {
            errorMessage = "The workspace choice could not be saved. Refresh and review it again."
        }
    }

    func cancelPendingSelection() {
        guard !isBusy else { return }
        pendingSelection = nil
        errorMessage = nil
    }

    func dismissCommittedSelection() {
        committedSelection = nil
    }

    private func prepare(_ makeSelection: () async throws -> WorkspaceAuthoritySelection) async {
        guard !isBusy else { return }
        isBusy = true
        pendingSelection = nil
        committedSelection = nil
        initializedEntry = nil
        errorMessage = nil
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            let selection = try await makeSelection()
            try Task.checkCancellation()
            pendingSelection = selection
        } catch is CancellationError {
        } catch {
            errorMessage = "This migration needs another review before the workspace choice can be prepared."
        }
    }

    private func perform(clearPending: Bool, _ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        if clearPending { pendingSelection = nil }
        errorMessage = nil
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
        } catch is CancellationError {
        } catch {
            errorMessage = "The migration review could not refresh. Try again."
        }
    }
}
