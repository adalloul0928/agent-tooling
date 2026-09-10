import AgentToolingCore
import Foundation

/// A precomputed overlay over the plugin rows the Library already read, so the
/// browser and its table columns never recompute an update verdict per cell.
///
/// The original index also folded in a marketplace comparison. That comparison
/// needs `WorkspaceMarketplaceSession`, which belongs to Discover and is being
/// built by a different port, so every plugin here reports "not checked" until
/// that session exists for a later phase to ask.
struct PluginInventoryIndex {
    let rows: [WorkspaceLibraryReadModelRow]
    let availability: [ArtifactID: UpdateAvailability]

    init(rows: [WorkspaceLibraryReadModelRow]) {
        self.rows = rows
        self.availability = Dictionary(
            uniqueKeysWithValues: rows.map {
                (
                    $0.artifactID,
                    UpdateAvailability.notChecked(
                        reason: "Discover's marketplace comparison isn't connected to Plugins yet.")
                )
            })
    }
}
