import Foundation

/// The identity-map entry a catalog source record cannot exist without.
///
/// `WorkspaceConfigurationState.validate` requires one allocation per catalog
/// source, and requires the allocation's live object to still be there. A source
/// nobody migrated has no legacy identifier to allocate against, so its own
/// lowercase UUID is used: unique by construction, stable for the life of the
/// record, and not a claim that some earlier database ever held it.
///
/// Adding and removing a source both go through here, so the record and its
/// allocation can never be written or withdrawn separately.
public enum WorkspaceCatalogSourceIdentity {
    public static func legacyKey(for id: WorkspaceObjectID) -> LegacyReferenceKey {
        .init(domain: .catalogSource, identifier: id.rawValue.uuidString.lowercased())
    }

    public static func entry(for id: WorkspaceObjectID) -> WorkspaceMigrationIdentityEntry {
        .init(legacy: legacyKey(for: id), objectID: id)
    }

    /// The allocation that names this source, whatever identifier it was
    /// allocated under. A migrated source keeps its original legacy identifier,
    /// so removal must find the entry by object rather than by recomputing one.
    public static func entry(
        for id: WorkspaceObjectID, in state: WorkspaceConfigurationState
    ) -> WorkspaceMigrationIdentityEntry? {
        state.identityMap.first { $0.legacy.domain == .catalogSource && $0.objectID == id }
    }
}
