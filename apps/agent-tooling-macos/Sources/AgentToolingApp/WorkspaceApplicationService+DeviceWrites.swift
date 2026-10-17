import AgentToolingCore
import Foundation
import os

/// Recording one change to this Mac's own record.
///
/// A protocol rather than the service itself so a test can make a chosen write
/// fail and look at what the session shows afterwards, the same way
/// `DeviceObserving` lets a test hand in a scan.
protocol DeviceStateRecording: Sendable {
    /// Applies `change` to this Mac's record as the store holds it now, and
    /// returns the record as it was written.
    func recordDeviceChange(
        _ change: @escaping @Sendable (inout DeviceWorkspaceState) throws -> Void
    ) async throws -> DeviceWorkspaceState
}

/// Device writes that read the head in the same call that commits.
///
/// Reading the head in one call and committing in another leaves a gap that
/// any other write on the service can land in, which then rejects this one as
/// stale. Read and committed together, nothing else on this service can come
/// between them. A writer on another actor or in another process still can, in
/// that instant; each change here is applied to the store's own copy inside the
/// transaction, never to one read earlier, so committing it on the newer head
/// is the same change, and it is tried again a few times rather than reported.
extension WorkspaceApplicationService: DeviceStateRecording {
    func recordDeviceChange(
        _ change: @escaping @Sendable (inout DeviceWorkspaceState) throws -> Void
    ) throws -> DeviceWorkspaceState {
        let written = OSAllocatedUnfairLock<DeviceWorkspaceState?>(initialState: nil)
        _ = try atCurrentHead { head in
            try commitDeviceChange(expectedRevisionID: head) { device in
                try change(&device)
                let recorded = device
                written.withLock { $0 = recorded }
            }
        }
        guard let device = written.withLock({ $0 }) else { throw WorkspaceRevisionStoreError.corruptState }
        return device
    }

    /// One change to a row of the device registry.
    func updateDeviceAtCurrentHead(
        _ id: WorkspaceObjectID, _ change: DeviceRegistryChange
    ) throws -> WorkspaceCommandReceipt {
        try atCurrentHead { head in
            try updateDevice(.init(expectedRevisionID: head, deviceID: id, change: change))
        }
    }

    /// Adds a device to the registry, or refreshes its row.
    func registerDeviceAtCurrentHead(_ id: WorkspaceObjectID, name: String) throws -> WorkspaceCommandReceipt {
        try atCurrentHead { head in
            try registerDevice(.init(expectedRevisionID: head, deviceID: id, name: name))
        }
    }

    /// Runs `commit` against the head as it is now, and again against a newer
    /// one if another writer moved it in between, up to three tries in all.
    private func atCurrentHead<T>(_ commit: (WorkspaceObjectID) throws -> T) throws -> T {
        var attempt = 1
        while true {
            guard let head = try snapshot()?.document.revision.id else {
                throw WorkspaceRevisionStoreError.notInitialized
            }
            do {
                return try commit(head)
            } catch WorkspaceRevisionStoreError.staleRevision where attempt < 3 {
                attempt += 1
            }
        }
    }
}
