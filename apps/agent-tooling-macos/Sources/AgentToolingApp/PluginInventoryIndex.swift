import AgentToolingCore
import Foundation

/// The plugin rows the Library already read, kept under their own name so a
/// caller reads like what it draws.
///
/// This index used to also fabricate an update-availability map, before
/// `PluginUpdateEvaluation` existed to answer that honestly. Nothing has read
/// it from here since, so it carries only what the browser still asks it for.
struct PluginInventoryIndex {
    let rows: [WorkspaceLibraryReadModelRow]
}
