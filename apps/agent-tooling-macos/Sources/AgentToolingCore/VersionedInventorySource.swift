import Foundation

/// Reads a workspace in the shape the integration surfaces speak.
///
/// It exists so the CLI and the MCP server answer from the same library the app
/// shows, projected once rather than assembled differently by each caller.
public struct VersionedInventorySource: Sendable {
    private let store: WorkspaceRevisionStore

    /// `nil` when the retained legacy library is still the authority, which is
    /// the ordinary case before a person migrates.
    ///
    /// A selection that names a store this Mac cannot open is a failure, not an
    /// absence: it throws rather than falling back, because falling back would
    /// silently answer from the library the person moved away from.
    /// Wraps a store this caller already opened.
    public init(store: WorkspaceRevisionStore) {
        self.store = store
    }

    /// Read fresh every time, so an item added in the app between two calls is
    /// visible on the second without restarting anything.
    public func inventory() throws -> VersionedInventoryProjection.Inventory {
        guard let snapshot = try store.snapshot() else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        return VersionedInventoryProjection.inventory(try WorkspaceLibraryReadModel(snapshot: snapshot))
    }

    /// The whole read-only picture, in the shape the integration surfaces speak.
    ///
    /// Everything comes from the versioned store: items from the library,
    /// client observations from this device's own state, and receipts from where
    /// operations record them. Nothing is left for a second store to supply.
    public func workspaceSnapshot(receiptLimit: Int = 50) throws -> WorkspaceSnapshot {
        guard let snapshot = try store.snapshot() else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        let inventory = VersionedInventoryProjection
            .inventory(try WorkspaceLibraryReadModel(snapshot: snapshot))
        return .init(
            skills: inventory.skills, mcpServers: inventory.mcpServers, plugins: inventory.plugins,
            operationReceipts: try store.operationReceipts(limit: receiptLimit),
            targetObservations: snapshot.device.observations)
    }

    /// The queue an agent adds to and a person answers.
    public var requestStore: WorkspaceRevisionStore { store }
}
