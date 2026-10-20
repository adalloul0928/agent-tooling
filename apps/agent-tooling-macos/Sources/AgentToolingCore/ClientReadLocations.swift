import Foundation

/// An adapter's declared files, folders and commands, shared by its scan and
/// setup's consent manifest. Scans retain overlapping reads for their distinct
/// purposes; the manifest collapses duplicate and nested roots.
struct ClientReadLocations: Sendable, Hashable {
    let client: ClientKind
    /// Configuration files, in the order they are read.
    let configurationFiles: [URL]
    /// Folders walked for skills.
    let skillRoots: [URL]
    /// Folders that hold the app's plugins or extensions.
    let pluginRoots: [URL]
    /// The argument lists the scan runs the app's own tool with,
    /// `versionArguments` first.
    let commands: [[String]]

    /// Asks a tool for its version.
    static let versionArguments = ["--version"]
    /// Asks Claude Code or Codex for the plugins it installed.
    static let pluginListArguments = ["plugin", "list", "--json"]
    /// Asks Codex for the connections it was configured with.
    static let mcpListArguments = ["mcp", "list", "--json"]

    /// Whether the scan runs the tool with `arguments`. A command the
    /// declaration does not hold is never run, so the manifest lists every
    /// command a read runs.
    func runs(_ arguments: [String]) -> Bool {
        commands.contains(arguments)
    }

    /// What the bundled adapter for `client` declares for `homeURL`.
    static func declared(for client: ClientKind, homeURL: URL) -> ClientReadLocations {
        ClientAdapterRegistry.bundledAdapter(for: client).readLocations(homeURL: homeURL)
    }
}

/// An adapter whose scan reads only what it declares.
protocol DeclaresLocalReads {
    /// The files, folders and commands a scan of `homeURL` reads and runs.
    func readLocations(homeURL: URL) -> ClientReadLocations
}
