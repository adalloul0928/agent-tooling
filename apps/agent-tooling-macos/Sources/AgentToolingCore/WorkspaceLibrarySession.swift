import Foundation
import Observation

/// Read-only is the default for migration previews. Writable sessions are
/// explicitly supplied by a trusted owner; this flag is not operator authority.
public enum WorkspaceLibraryAccess: Sendable {
    case readOnly, writable
}

public struct WorkspaceLibraryState: Sendable, Equatable {
    public let snapshot: WorkspaceApplicationSnapshot
    public let library: WorkspaceLibraryReadModel

    public init(snapshot: WorkspaceApplicationSnapshot) throws {
        self.snapshot = snapshot
        self.library = try WorkspaceLibraryReadModel(snapshot: snapshot)
    }
}

public protocol WorkspaceLibraryServing: Sendable {
    func libraryState() async throws -> WorkspaceLibraryState
    func previewAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) async throws -> WorkspaceAssignmentBatchPreview
    func applyAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) async throws -> WorkspaceCommandReceipt
}

public struct WorkspaceAssignmentReview: Sendable, Equatable {
    public let command: WorkspaceAssignmentBatchCommand
    public let preview: WorkspaceAssignmentBatchPreview
}

/// Explicitly bound to one workspace and device. This session never discovers,
/// initializes, migrates, or selects a store, and never writes native clients.
/// The only session the app's screens read from.
@MainActor @Observable
public final class WorkspaceLibrarySession {
    public let workspaceID: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    public let access: WorkspaceLibraryAccess
    public private(set) var state: WorkspaceLibraryState?
    public private(set) var review: WorkspaceAssignmentReview?
    public private(set) var lastReceipt: WorkspaceCommandReceipt?
    public private(set) var errorMessage: String?
    /// The assignment refusal behind `errorMessage`, when there was one, so a
    /// screen can offer the right next step instead of only the words.
    public private(set) var lastRefusal: WorkspaceAssignmentCommandError?
    public private(set) var isBusy = false
    @ObservationIgnored private let service: any WorkspaceLibraryServing
    /// Callers waiting for the work in flight to finish, and how many reads
    /// have landed, so a waiter can tell a read newer than its call from the
    /// one it already had.
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var readsLanded = 0

    public init(service: any WorkspaceLibraryServing, workspaceID: WorkspaceObjectID,
                deviceID: WorkspaceObjectID, access: WorkspaceLibraryAccess = .readOnly) {
        self.service = service
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.access = access
    }

    /// Reads the library. When this returns, a read newer than the call has
    /// landed, or an error says why not, or the caller was cancelled.
    ///
    /// Work already in flight is shared rather than skipped: the shell starts
    /// reading the moment the window is up, and a screen asking during that read
    /// must get its answer, not an early return that leaves "no library yet"
    /// looking like the answer. A command in flight re-reads before it finishes,
    /// so waiting for it is the same read.
    public func refresh() async {
        let asked = readsLanded
        while isBusy {
            await withCheckedContinuation { waiters.append($0) }
            if Task.isCancelled || readsLanded > asked { return }
        }
        isBusy = true
        defer { settle() }
        review = nil
        errorMessage = nil
        lastRefusal = nil
        do {
            let next = try await service.libraryState()
            try Task.checkCancellation()
            try accept(next)
        } catch is CancellationError {
            // Keep the last complete read model, never a partial result.
        } catch {
            errorMessage = message(for: error)
        }
    }

    public func reviewAssignments(artifactIDs: [ArtifactID], destinations: [PortableDestination]) async {
        await prepare { snapshot in
            try .assign(document: snapshot.document, artifactIDs: artifactIDs, destinations: destinations)
        }
    }

    public func reviewPreset(presetID: ArtifactID, destinations: [PortableDestination]) async {
        await prepare { snapshot in
            try .applyPresetOnce(document: snapshot.document, presetID: presetID, destinations: destinations)
        }
    }

    public func reviewRemoval(contributionIDs: [WorkspaceObjectID]) async {
        await prepare { snapshot in
            .init(expectedRevisionID: snapshot.document.revision.id, removalIDs: contributionIDs)
        }
    }

    public func discardReview() {
        guard !isBusy else { return }
        review = nil
        lastReceipt = nil
        errorMessage = nil
        lastRefusal = nil
    }

    /// The success receipt records desired intent only. Native deployment is a
    /// separate reviewed operation and must not be reported as completed here.
    public func applyReviewedAssignments() async {
        guard !isBusy else { return }
        guard access == .writable else {
            errorMessage = "This workspace is open for review. Assignments cannot be saved here."
            return
        }
        guard let reviewed = review else { return }
        isBusy = true
        defer { settle() }
        errorMessage = nil
        lastRefusal = nil
        do {
            try Task.checkCancellation()
            let receipt = try await service.applyAssignmentBatch(reviewed.command)
            // A durable commit remains a success even if refresh is cancelled or
            // fails afterwards. Never invite a second write to repair a read.
            lastReceipt = receipt
            review = nil
            do {
                let next = try await service.libraryState()
                try Task.checkCancellation()
                try accept(next)
            } catch is CancellationError {
                errorMessage = "Assignments were saved. Refresh the library to see the current state."
            } catch {
                errorMessage = "Assignments were saved, but the library could not refresh. \(message(for: error))"
            }
        } catch is CancellationError {
            // Retry retains the same command/idempotency key if the caller was
            // interrupted before receiving a durable result.
        } catch {
            errorMessage = message(for: error)
            if case WorkspaceRevisionStoreError.staleRevision = error { review = nil }
        }
    }

    private func prepare(_ makeCommand: (WorkspaceApplicationSnapshot) throws -> WorkspaceAssignmentBatchCommand) async {
        guard !isBusy else { return }
        isBusy = true
        defer { settle() }
        review = nil
        lastReceipt = nil
        errorMessage = nil
        lastRefusal = nil
        do {
            // Re-read before reviewing: choices are IDs, not authority to replay
            // a view's stale document or silently replace another writer's edit.
            let next = try await service.libraryState()
            try Task.checkCancellation()
            try accept(next)
            let command = try makeCommand(next.snapshot)
            let preview = try await service.previewAssignmentBatch(command)
            try Task.checkCancellation()
            review = .init(command: command, preview: preview)
        } catch is CancellationError {
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func accept(_ next: WorkspaceLibraryState) throws {
        guard next.snapshot.document.workspaceID == workspaceID,
              next.snapshot.device.workspaceID == workspaceID,
              next.snapshot.device.deviceID == deviceID else {
            throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
        }
        state = next
        readsLanded += 1
    }

    /// Ends a busy span and wakes whoever was waiting for it, so they can look
    /// at what it left behind.
    private func settle() {
        isBusy = false
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private func message(for error: any Error) -> String {
        lastRefusal = error as? WorkspaceAssignmentCommandError
        if let error = error as? WorkspaceAssignmentCommandError {
            switch error {
            case .emptyBatch: return "Choose at least one item and one destination."
            case .duplicateSelection: return "Some choices are repeated. Review your selection."
            case .unsupportedArtifact: return "Some items are tracked only or cannot be assigned. Review their ownership first."
            case .nativeChild: return "Choose the whole plugin to include its skills and tools."
            case .contributionConflict:
                return "These items are already asked for in those apps. "
                    + "Installing them is the next step, on the Apps screen."
            case .missingContribution: return "An assignment was already removed. Refresh the library."
            case .presetChanged, .invalidPresetReview: return "The preset changed. Review its current items before continuing."
            case .unsupportedReason: return "This assignment belongs to another workflow. Open its configuration to change it."
            }
        }
        return String(SensitiveValueRedactor.redact(error.localizedDescription).prefix(2_048))
    }
}
