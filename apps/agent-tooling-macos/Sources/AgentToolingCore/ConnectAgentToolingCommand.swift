import Foundation

/// Why Agent Tooling's own connection could not be recorded, in the words a
/// screen can show.
enum ConnectAgentToolingError: LocalizedError, Equatable, Sendable {
    /// The helper is not in a copy that stays put: it is on a disk image, in
    /// the temporary place macOS runs a downloaded app from, or not inside an
    /// app at all. An app would keep a path that stops working.
    case helperNotInApplications(String)

    var errorDescription: String? {
        switch self {
        case .helperNotInApplications:
            "Agent Tooling’s helper can be connected only from a copy in Applications. Nothing was changed."
        }
    }
}

/// Records the shared connection, this Mac's helper binding and its app
/// contributions in one revision. Paths stay device-local; another Mac supplies
/// its own binding. An existing manually tracked row keeps its identity.
/// Registration happens later through a reviewed plan.
public struct ConnectAgentToolingCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    let idempotencyKey: WorkspaceObjectID
    /// The helper this Mac's apps start: `Contents/Helpers/agent-tooling-mcp`
    /// inside a copy in Applications.
    public let helperPath: String
    /// The apps on this Mac the connection is meant for. Exactly these hold
    /// this Mac's contributions afterwards; other Macs' are left alone.
    public let apps: Set<ClientKind>
    /// The identity a new connection takes when the library holds none yet.
    public let artifactID: ArtifactID

    /// Refuses a helper path an app could not keep: one on a mounted volume,
    /// one macOS translocated, one not inside an app's `Contents/Helpers`, or
    /// one the connection rules refuse.
    public init(
        expectedRevisionID: WorkspaceObjectID, idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(), helperPath: String,
        apps: Set<ClientKind>, artifactID: ArtifactID = ArtifactID()
    ) throws {
        guard Self.accepts(helperPath: helperPath) else { throw ConnectAgentToolingError.helperNotInApplications(helperPath) }
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.helperPath = helperPath
        self.apps = apps
        self.artifactID = artifactID
    }

    /// Whether an app may keep `helperPath`: an absolute path to
    /// `Contents/Helpers/agent-tooling-mcp` inside an app bundle, not on a
    /// mounted volume and not in the temporary place macOS translocates a
    /// download to, that the connection rules accept as a command. The one
    /// rule the installation's `registrableHelperPath` and this command share,
    /// so a path the stage offers is never one the command refuses.
    static func accepts(helperPath: String) -> Bool {
        let components = URL(filePath: helperPath).standardizedFileURL.pathComponents
        guard helperPath.hasPrefix("/"),
            components.count > 5,
            components[1] != "Volumes",
            !components.contains("AppTranslocation"),
            components[components.count - 4].lowercased().hasSuffix(".app"),
            Array(components.suffix(3)) == ["Contents", "Helpers", "agent-tooling-mcp"]
        else { return false }
        return (try? MCPDefinitionValidator.validateCommandArguments([helperPath])) != nil
    }

    /// The library and this Mac as they would stand once this is recorded,
    /// worked out in memory and written nowhere: what a plan of the steps it
    /// would lead to is built from. Also the connection's identity, or nil
    /// when there is none and none is wanted.
    public func preview(
        of snapshot: WorkspaceApplicationSnapshot, deviceID: WorkspaceObjectID
    ) throws -> (snapshot: WorkspaceApplicationSnapshot, connection: ArtifactID?) {
        var document = snapshot.document
        var device = snapshot.device
        let connection = try apply(to: &document, deviceID: deviceID)
        try bind(&device, connection: connection)
        return (WorkspaceApplicationSnapshot(document: document, device: device), connection)
    }

    /// What the command asks for, without the revision it was read at: a
    /// retry against a newer head is the same request, so replaying it
    /// returns the first result.
    func inputDigest() -> String {
        framedDigest(
            fields: [
                "connect-agent-tooling.v1",
                idempotencyKey.rawValue.uuidString.lowercased(),
                artifactID.rawValue.uuidString.lowercased(),
                helperPath,
            ] + ClientKind.allCases.filter(apps.contains).map(\.rawValue))
    }

    /// The portable half: the connection, if the library has none yet, and
    /// this Mac's contributions made equal to `apps`. Returns the
    /// connection's identity, or nil when there is none and none is wanted.
    func apply(to document: inout PortableWorkspaceDocument, deviceID: WorkspaceObjectID) throws -> ArtifactID? {
        guard document.mcpDefinitions != nil else {
            throw WorkspaceDomainValidationError.unsupportedVersion(document.schemaVersion)
        }
        let connection: ArtifactID
        if let own = AgentToolingConnection.ownConnection(in: document) {
            connection = own.identity.id
        } else if let tracked = document.artifacts.firstIndex(where: Self.isTrackedRegistration) {
            // A hand registration the read tracked becomes this connection in
            // place, so whatever already refers to that row still does.
            connection = document.artifacts[tracked].identity.id
            document.artifacts[tracked].authority = .centralPersonal
            document.artifacts[tracked].identity.displayName = AgentToolingConnection.displayName
            document.artifacts[tracked].declaredName = AgentToolingConnection.declaredName
            document.mcpDefinitions?.removeAll { $0.artifactID == connection }
            document.mcpDefinitions?.append(.init(artifactID: connection, connection: .deviceBound(transport: .stdio)))
        } else if apps.isEmpty {
            return nil
        } else {
            let intake = try ManagedMCPServerIntakeCommand(
                expectedRevisionID: expectedRevisionID, idempotencyKey: idempotencyKey, artifactID: artifactID,
                displayName: AgentToolingConnection.displayName, stdioCommand: [helperPath])
            _ = try intake.apply(to: &document)
            connection = artifactID
        }

        let wanted = Set(apps.map { Self.destination(for: $0, deviceID: deviceID) })
        var kept = Set<PortableDestination>()
        document.assignments.removeAll { contribution in
            guard contribution.artifactID == connection, contribution.destination.deviceIDs == [deviceID] else {
                return false
            }
            guard contribution.reason == .manual, wanted.contains(contribution.destination),
                kept.insert(contribution.destination).inserted
            else { return true }
            return false
        }
        for app in ClientKind.allCases where apps.contains(app) {
            let destination = Self.destination(for: app, deviceID: deviceID)
            guard !kept.contains(destination) else { continue }
            document.assignments.append(.init(artifactID: connection, destination: destination, reason: .manual))
        }
        try document.validateStructure()
        return connection
    }

    /// This Mac's half: the helper's path in this Mac's binding, added or
    /// replaced, with nothing to sign in to.
    func bind(_ device: inout DeviceWorkspaceState, connection: ArtifactID?) throws {
        guard let connection else { return }
        guard device.mcpBindings != nil else {
            throw WorkspaceDomainValidationError.unsupportedVersion(device.schemaVersion)
        }
        let binding = DeviceMCPDefinitionBinding(
            artifactID: connection, destination: .stdio(executable: helperPath, arguments: []), authenticationRequirement: .none)
        if let index = device.mcpBindings?.firstIndex(where: { $0.artifactID == connection }) {
            device.mcpBindings?[index] = binding
        } else {
            device.mcpBindings?.append(binding)
        }
    }

    /// Where one app's contribution goes: the app's own surface, for the
    /// person, on this Mac alone.
    static func destination(for app: ClientKind, deviceID: WorkspaceObjectID) -> PortableDestination {
        PortableDestination(surface: app.defaultSurface, scope: .user, deviceIDs: [deviceID])
    }

    /// A standalone server the read tracked under this connection's name.
    private static func isTrackedRegistration(_ artifact: ArtifactRecord) -> Bool {
        artifact.identity.kind == .mcpServer && artifact.authority == .trackedOnly && artifact.identity.parentPackageID == nil
            && artifact.declaredName?.compare(AgentToolingConnection.declaredName, options: .caseInsensitive) == .orderedSame
    }
}
