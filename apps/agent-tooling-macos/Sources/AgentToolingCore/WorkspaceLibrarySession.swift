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
    public private(set) var isBusy = false
    @ObservationIgnored private let service: any WorkspaceLibraryServing

    public init(service: any WorkspaceLibraryServing, workspaceID: WorkspaceObjectID,
                deviceID: WorkspaceObjectID, access: WorkspaceLibraryAccess = .readOnly) {
        self.service = service
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.access = access
    }

    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        review = nil
        errorMessage = nil
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
        defer { isBusy = false }
        errorMessage = nil
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
        defer { isBusy = false }
        review = nil
        lastReceipt = nil
        errorMessage = nil
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
    }

    private func message(for error: any Error) -> String {
        if let error = error as? WorkspaceAssignmentCommandError {
            switch error {
            case .emptyBatch: return "Choose at least one item and one destination."
            case .duplicateSelection: return "Some choices are repeated. Review your selection."
            case .unsupportedArtifact: return "Some items are tracked only or cannot be assigned. Review their ownership first."
            case .nativeChild: return "Choose the whole plugin to include its skills and tools."
            case .contributionConflict: return "An assignment already exists for these choices. Refresh and review the current assignments."
            case .missingContribution: return "An assignment was already removed. Refresh the library."
            case .presetChanged, .invalidPresetReview: return "The preset changed. Review its current items before continuing."
            case .unsupportedReason: return "This assignment belongs to another workflow. Open its configuration to change it."
            }
        }
        return String(SensitiveValueRedactor.redact(error.localizedDescription).prefix(2_048))
    }
}
