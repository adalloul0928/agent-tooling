import Foundation

/// Why a declared connection cannot be delivered to a particular app.
public enum AgentPluginMCPRouteRefusal: String, Error, Hashable, Sendable, CaseIterable {
    /// This app has no recorded evidence that it accepts MCP connections.
    case noRecordedSupport
    /// This app does not accept this transport.
    case unsupportedTransport
    /// A `${...}` this build does not define. Passing it through unexpanded
    /// would become a wrong path that looks like a right one.
    case unknownPlaceholder
    /// After expansion, the path resolves outside the package or its data.
    case escapesPackage
    /// The package root or its data folder is not a usable directory here.
    case missingRoot
    /// The declared executable is not in the package and not a bare name the
    /// platform can resolve.
    case missingExecutable
}

/// One connection, resolved for one app on this Mac.
public struct ResolvedPluginMCPServer: Hashable, Sendable {
    public let name: String
    public let surface: TargetSurface
    public let transport: String
    /// Absolute for a command inside the package; a bare name otherwise, which
    /// the client resolves by its own PATH rules.
    public let executable: String?
    public let arguments: [String]
    /// The package's declared variables plus the two the client owns. The
    /// client-owned pair always wins.
    public let environment: [String: String]
    public let workingDirectory: String?
    public let endpoint: String?
    public let headers: [String: String]
}

public struct AgentPluginMCPRouteResult: Hashable, Sendable {
    public let resolved: [ResolvedPluginMCPServer]
    public let refused: [Refusal]

    public struct Refusal: Hashable, Sendable {
        public let name: String
        public let surface: TargetSurface
        public let reason: AgentPluginMCPRouteRefusal
        /// Static description. Never contains a path, endpoint or credential.
        public let detail: String
    }
}

/// Turns a package's declared MCP connections into what a specific app on this
/// Mac would actually be given.
///
/// Parsing a declaration says it is well-formed. It does not say any app can
/// use it, and this is the step that decides. Every refusal is named and
/// returned: a connection that cannot be delivered is reported, never dropped,
/// because a silently missing server looks exactly like one that was never
/// declared.
///
/// This maps; it does not launch. Nothing here starts a process or opens a
/// connection, and a resolved route is not evidence that the server works.
public enum AgentPluginMCPRuntimeMapper {
    /// The two variables the client owns. A package cannot set them — that is
    /// refused at parse time — and here they always win over anything declared.
    public static let clientOwnedVariables = ["PLUGIN_ROOT", "PLUGIN_DATA"]

    /// `dataRoot` is the package's persistent folder. It belongs to the client
    /// and survives updates, which is what makes it different from the package
    /// root: content is replaced on update, data is not.
    public static func resolve(
        servers: [String: AgentPluginMCPServerDeclaration],
        packageRoot: URL,
        dataRoot: URL,
        surface: TargetSurface,
        evidence: [TargetCapabilityEvidence],
        fileManager: FileManager = .default
    ) -> AgentPluginMCPRouteResult {
        var resolved: [ResolvedPluginMCPServer] = []
        var refused: [AgentPluginMCPRouteResult.Refusal] = []
        func refuse(_ name: String, _ reason: AgentPluginMCPRouteRefusal, _ detail: String) {
            refused.append(.init(name: name, surface: surface, reason: reason, detail: detail))
        }

        let supported = Set(evidence
            .filter { $0.surface == surface && $0.component == .mcpServer && $0.support == .supported }
            .compactMap(\.transport))
        let roots: (root: URL, data: URL)?
        if let root = directory(packageRoot, fileManager), let data = directory(dataRoot, fileManager) {
            roots = (root, data)
        } else {
            roots = nil
        }

        for name in servers.keys.sorted() {
            guard let declaration = servers[name] else { continue }
            guard !supported.isEmpty else {
                refuse(name, .noRecordedSupport,
                       "This Mac has no recorded evidence that this app accepts MCP connections.")
                continue
            }
            guard supported.contains(declaration.transport) else {
                refuse(name, .unsupportedTransport, "This app does not accept this connection type.")
                continue
            }
            guard let roots else {
                refuse(name, .missingRoot, "The package folder or its data folder is not usable here.")
                continue
            }
            switch declaration {
            case .stdio(let server):
                guard let entry = stdio(name: name, server: server, roots: roots,
                                        surface: surface, fileManager: fileManager, refuse: refuse) else { continue }
                resolved.append(entry)
            case .streamableHTTP(let server), .sse(let server):
                resolved.append(.init(
                    name: name, surface: surface, transport: declaration.transport,
                    executable: nil, arguments: [],
                    environment: clientEnvironment(roots: roots),
                    workingDirectory: nil, endpoint: server.url,
                    // Bound to this endpoint's own origin. This build does not
                    // follow a redirect on the package's behalf, so a header
                    // never travels to a host the declaration did not name.
                    headers: server.headers))
            }
        }
        return .init(resolved: resolved, refused: refused.sorted { $0.name < $1.name })
    }

    private static func stdio(
        name: String,
        server: AgentPluginStdioServer,
        roots: (root: URL, data: URL),
        surface: TargetSurface,
        fileManager: FileManager,
        refuse: (String, AgentPluginMCPRouteRefusal, String) -> Void
    ) -> ResolvedPluginMCPServer? {
        // A bare command is the platform's to resolve; this build does not
        // search PATH and does not claim the executable exists.
        var executable = server.command
        if server.command.hasPrefix("./") || server.command.contains("${") {
            switch expandPath(server.command, roots: roots) {
            case .failure(let reason):
                refuse(name, reason, detail(for: reason))
                return nil
            case .success(let url):
                guard fileManager.isExecutableFile(atPath: url.path) else {
                    refuse(name, .missingExecutable,
                           "The package does not contain a runnable file at the place it names.")
                    return nil
                }
                executable = url.path
            }
        }

        var workingDirectory: String?
        if let declared = server.currentDirectory {
            switch expandPath(declared, roots: roots) {
            case .failure(let reason):
                refuse(name, reason, detail(for: reason))
                return nil
            case .success(let url):
                guard directory(url, fileManager) != nil else {
                    refuse(name, .missingRoot, "The folder it asks to run in is not there.")
                    return nil
                }
                workingDirectory = url.path
            }
        }

        var environment: [String: String] = [:]
        for (key, value) in server.environment {
            switch expandText(value, roots: roots) {
            case .failure(let reason):
                refuse(name, reason, detail(for: reason))
                return nil
            case .success(let expanded):
                environment[key] = expanded
            }
        }
        var arguments: [String] = []
        for argument in server.arguments {
            switch expandText(argument, roots: roots) {
            case .failure(let reason):
                refuse(name, reason, detail(for: reason))
                return nil
            case .success(let expanded):
                arguments.append(expanded)
            }
        }
        // The client's own pair is applied last, so nothing declared can shadow
        // where the package or its data actually live.
        environment.merge(clientEnvironment(roots: roots)) { _, client in client }

        return .init(name: name, surface: surface, transport: "stdio", executable: executable,
                     arguments: arguments, environment: environment,
                     workingDirectory: workingDirectory, endpoint: nil, headers: [:])
    }

    private static func clientEnvironment(roots: (root: URL, data: URL)) -> [String: String] {
        ["PLUGIN_ROOT": roots.root.path, "PLUGIN_DATA": roots.data.path]
    }

    /// Expands the two known variables and refuses every other `${...}`.
    private static func expandText(
        _ value: String, roots: (root: URL, data: URL)
    ) -> Result<String, AgentPluginMCPRouteRefusal> {
        let expanded = value
            .replacingOccurrences(of: "${PLUGIN_ROOT}", with: roots.root.path)
            .replacingOccurrences(of: "${PLUGIN_DATA}", with: roots.data.path)
        guard !expanded.contains("${") else { return .failure(.unknownPlaceholder) }
        return .success(expanded)
    }

    /// Expands a path and then checks where it actually lands, following any
    /// symlink first. A link inside the package pointing outside it is the
    /// case this exists for.
    private static func expandPath(
        _ value: String, roots: (root: URL, data: URL)
    ) -> Result<URL, AgentPluginMCPRouteRefusal> {
        let base: URL
        var relative = value
        if value.hasPrefix("./") {
            base = roots.root
            relative = String(value.dropFirst(2))
        } else if value == "${PLUGIN_ROOT}" || value.hasPrefix("${PLUGIN_ROOT}/") {
            base = roots.root
            relative = value == "${PLUGIN_ROOT}" ? "" : String(value.dropFirst("${PLUGIN_ROOT}/".count))
        } else if value == "${PLUGIN_DATA}" || value.hasPrefix("${PLUGIN_DATA}/") {
            base = roots.data
            relative = value == "${PLUGIN_DATA}" ? "" : String(value.dropFirst("${PLUGIN_DATA}/".count))
        } else {
            return .failure(.unknownPlaceholder)
        }
        guard !relative.contains("${") else { return .failure(.unknownPlaceholder) }
        let candidate = (relative.isEmpty ? base : base.appending(path: relative))
            .resolvingSymlinksInPath().standardizedFileURL
        let anchor = base.resolvingSymlinksInPath().standardizedFileURL
        let anchorPath = normalized(anchor)
        let candidatePath = normalized(candidate)
        guard candidatePath == anchorPath || candidatePath.hasPrefix(anchorPath + "/") else {
            return .failure(.escapesPackage)
        }
        return .success(candidate)
    }

    private static func detail(for reason: AgentPluginMCPRouteRefusal) -> String {
        switch reason {
        case .unknownPlaceholder:
            "It uses a variable Agent Tooling does not define, so it cannot be filled in."
        case .escapesPackage:
            "It points outside the package once the variables are filled in."
        case .missingRoot: "The package folder or its data folder is not usable here."
        case .missingExecutable: "The package does not contain a runnable file at the place it names."
        case .noRecordedSupport:
            "This Mac has no recorded evidence that this app accepts MCP connections."
        case .unsupportedTransport: "This app does not accept this connection type."
        }
    }

    private static func directory(_ url: URL, _ fileManager: FileManager) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return resolved
    }

    private static func normalized(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
