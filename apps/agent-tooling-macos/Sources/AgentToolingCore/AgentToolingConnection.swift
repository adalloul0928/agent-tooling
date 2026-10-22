import Foundation

/// Agent Tooling's own connection: the helper an app starts to look things up
/// in the library and to ask for changes, which a person reviews here.
///
/// One place knows its identity, the command each app is asked to run to add
/// it, and what each app on this Mac already has, so setup's preview and the
/// reviewed plan cannot name it differently.
public enum AgentToolingConnection {
    /// The name every app registers it under.
    public static let declaredName = "agent-tooling"
    /// The name a person sees.
    public static let displayName = "Agent Tooling"

    /// The tools it offers for looking things up, each with what it does in
    /// a person's words, in the order the helper lists them.
    public static let lookUpTools: [(name: String, words: String)] = [
        ("search_inventory", "Search your library"),
        ("get_component", "Read one tool’s details"),
        ("get_client_status", "See each app’s status"),
        ("get_effective_settings", "See an app’s settings in effect"),
        ("list_receipts", "List what was installed"),
        ("get_receipt", "Read one receipt"),
        ("list_pending_requests", "List requests waiting for you"),
        ("get_request_status", "Check one request"),
        ("open_review_screen", "Link to a review in Agent Tooling"),
    ]

    /// The tools it offers for asking for a change. Each only queues a
    /// request a person approves or declines here.
    public static let askTools: [(name: String, words: String)] = [
        ("request_add_mcp_server", "Ask to add a connection"),
        ("request_create_skill", "Ask to create a skill"),
        ("request_install_skill", "Ask to install a skill"),
        ("request_install_plugin", "Ask to install a plugin"),
        ("request_remove_component", "Ask to remove a tool"),
    ]

    /// Where an app stands with the connection on this Mac.
    public enum AppState: Equatable, Sendable {
        /// The app was not found here.
        case notFound
        /// The app was not checked on this Mac yet, so nothing is known.
        case notChecked
        /// The app is here but did not report a version, so whether it takes
        /// the command cannot be confirmed yet.
        case waitsForVersion
        /// The app is here and has no registration.
        case notConnected
        /// The app already runs this copy's helper. `provenOurs` is true only
        /// when a receipt shows Agent Tooling registered it there, so it may
        /// take it out again (D10); one somebody made by hand is theirs.
        case alreadyConnected(provenOurs: Bool)
        /// The app runs a helper at another path. `provenOurs` is true only
        /// when a receipt shows Agent Tooling registered it.
        case connectedToAnotherCopy(path: String, provenOurs: Bool)
    }

    /// Whether `artifact` is this connection as setup records it: a server
    /// in the person's own library, under this name, whose definition is a
    /// command bound to each Mac rather than an address every Mac shares.
    public static func isOwnConnection(_ artifact: ArtifactRecord, definitions: [PortableMCPDefinitionRecord]) -> Bool {
        guard artifact.identity.kind == .mcpServer, artifact.authority == .centralPersonal,
            artifact.declaredName == declaredName
        else { return false }
        return definitions.contains {
            $0.artifactID == artifact.identity.id && $0.connection == .deviceBound(transport: .stdio)
        }
    }

    /// The library's own connection, when it holds one.
    public static func ownConnection(in document: PortableWorkspaceDocument) -> ArtifactRecord? {
        let definitions = document.mcpDefinitions ?? []
        return document.artifacts.first { isOwnConnection($0, definitions: definitions) }
    }

    /// The apps the Mac `deviceID` has the library's own connection set up
    /// for: each one whose surface holds a contribution of the connection
    /// that names that Mac alone. Another Mac's choice, and a registration
    /// somebody made by hand under the same name, are not among them.
    public static func apps(on deviceID: WorkspaceObjectID, in document: PortableWorkspaceDocument) -> Set<ClientKind> {
        guard let own = ownConnection(in: document) else { return [] }
        return Set(
            document.assignments
                .filter { $0.artifactID == own.identity.id && $0.destination.deviceIDs == [deviceID] }
                .compactMap(\.destination.surface.client))
    }

    /// The arguments `client`'s own tool is given to take the connection out
    /// again, at user scope: exactly what a reviewed removal runs (D10).
    public static func previewRemovalArguments(client: ClientKind) -> [String] {
        MCPClientCommand.removeArguments(serverID: declaredName, client: client, scope: .user)
    }

    /// The arguments `client`'s own tool is given to add the helper at
    /// `helperPath`, at user scope: exactly what the reviewed plan runs, so a
    /// preview of it is the command itself. The tool is named by
    /// `ClientExecutableLocator.executableName(for:)`.
    public static func previewArguments(client: ClientKind, helperPath: String) -> [String] {
        MCPClientCommand.addArguments(
            serverID: declaredName, transport: .stdio,
            destination: ValidatedMCPDestination(endpoint: helperPath, command: [helperPath]), client: client, scope: .user)
    }

    /// Derives connection state from user-scope registrations; plugin and project
    /// registrations do not count. A matching helper path is connected; another
    /// command is a different copy. Receipts in `provenSurfaces` establish ownership.
    /// Missing observations, missing apps and unknown versions remain distinct.
    public static func states(
        observations: [TargetObservation], helperPath: String, provenSurfaces: Set<TargetSurface> = []
    ) -> [ClientKind: AppState] {
        Dictionary(
            uniqueKeysWithValues: ClientKind.allCases.map { client in
                (client, state(of: observation(for: client, in: observations), helperPath: helperPath, proven: provenSurfaces))
            })
    }

    /// The surfaces where a receipt shows Agent Tooling set this connection
    /// up and the step succeeded, with nothing taking it out of that app
    /// since: the proof that lets a registration pointing at another copy be
    /// replaced rather than left alone, and one pointing at this copy be
    /// taken out again. The rule every connection's proof follows
    /// (`WorkspaceDeploymentOperations.provenConnections(in:)`): only the
    /// step that added it counts, never the removal a replacement runs
    /// first, and a later removal for good ends it.
    public static func provenSurfaces(in receipts: [OperationReceipt]) -> Set<TargetSurface> {
        Set(WorkspaceDeploymentOperations.provenConnections(in: receipts).filter { $0.value.contains(declaredName) }.keys)
    }

    /// Whether two spellings of a command name one file: the same absolute
    /// path once links are resolved, or the same bare name.
    public static func sameCommand(_ command: String, _ other: String) -> Bool {
        normalized(command) == normalized(other)
    }

    // MARK: - Reading one app

    private static func observation(for client: ClientKind, in observations: [TargetObservation]) -> TargetObservation? {
        observations.first { $0.surface == client.defaultSurface } ?? observations.first { $0.surface.client == client }
    }

    private static func state(of observation: TargetObservation?, helperPath: String, proven: Set<TargetSurface>) -> AppState {
        guard let observation else { return .notChecked }
        guard observation.installed else { return .notFound }
        if let registration = observation.userScopeMCPRegistration(ofServer: declaredName) {
            let isOurs = proven.contains(observation.surface)
            if let command = registration.command, sameCommand(command, helperPath), registration.arguments == [] {
                return .alreadyConnected(provenOurs: isOurs)
            }
            return .connectedToAnotherCopy(path: registration.command ?? "", provenOurs: isOurs && registration.arguments == [])
        }
        let version = observation.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? .waitsForVersion : .notConnected
    }

    private static func normalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var standard = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        if standard.count > 1, standard.hasSuffix("/") { standard.removeLast() }
        return standard
    }
}
