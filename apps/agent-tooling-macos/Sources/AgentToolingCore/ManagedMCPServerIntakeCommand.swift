import Foundation

/// Why a connection was not recorded, in the words the screen shows.
///
/// A refusal from the definition validator keeps the validator's own message
/// rather than a restatement: it already explains credentials, control
/// characters and unmatched quotes better than anything written here would.
public enum ManagedMCPServerIntakeError: LocalizedError, Equatable, Sendable {
    case alreadyManaged(String)
    /// The name Agent Tooling's own connection goes by, which only setup's
    /// Let your apps ask records (`ConnectAgentToolingCommand`).
    case reservedName(String)
    case invalidConnectionName(String)
    case invalidCredentialName(String)
    case identityCollision
    case previouslyRemoved

    public var errorDescription: String? {
        switch self {
        case .alreadyManaged(let name):
            "A connection called \(name) is already in your library. Open it to change how it is reached."
        case .reservedName(let name):
            "\(name) is the name of Agent Tooling’s own connection, which setup’s Let your apps ask adds. "
                + "Choose another name. Nothing was saved."
        case .invalidConnectionName(let name):
            "\(name) is not a name this workspace will record for a connection. "
                + "Use lowercase letters, numbers and single hyphens."
        case .invalidCredentialName(let name):
            "\(name) is not a name this workspace will record. Rename it in the app that needs it, "
                + "or set it up through that app's own credential flow."
        case .identityCollision:
            "That identity is already used in this workspace."
        case .previouslyRemoved:
            "You removed a connection with this identity before. Add it back from the library rather than from a paste."
        }
    }
}

/// Records an MCP connection without starting, installing or authenticating it.
/// HTTPS endpoints with nonlocal, multilabel DNS hosts are portable. Stdio,
/// HTTP, IP literals and local hosts use device bindings.
/// Both halves exclude credentials: the parser drops header/environment values,
/// and validation rejects credential arguments, URL credentials or queries,
/// and credential requirement names that resemble secret values.
public struct ManagedMCPServerIntakeCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let displayName: String
    public let declaredName: String
    public let connection: PortableMCPConnection
    public let destination: DeviceMCPDestination?
    public let credentialRequirementNames: [String]
    public let authenticationRequirement: MCPAuthenticationRequirement
    public let workspaceRootPath: String?

    /// Validates and splits the draft. A draft that cannot be recorded is
    /// refused here, with the validator's own words.
    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID = ArtifactID(),
        draft: MCPDraft,
        credentialRequirementNames: [String] = []
    ) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try WorkspaceDomainValidation.requireText(name, field: "connection display name", maximum: 512)
        guard let identifier = try? WorkspaceLibrary.normalizedIdentifier(name) else {
            throw ManagedMCPServerIntakeError.invalidConnectionName(name)
        }

        let validated = try MCPDefinitionValidator.validate(draft.endpoint, transport: draft.transport)
        let split = try Self.split(validated, transport: draft.transport)
        let names = try Self.recordableCredentialNames(credentialRequirementNames)

        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        displayName = name
        declaredName = identifier
        connection = split.connection
        destination = split.destination
        self.credentialRequirementNames = names
        authenticationRequirement = Self.requirement(draft.authentication, credentialNames: names)
        // A project folder belongs to this Mac. A connection scoped to one is
        // still recorded without it: the resolver reports the missing local
        // setup at Install time, where it can be fixed, and refusing here would
        // lose the definition over a fact that belongs to one device.
        if draft.scope == .user {
            workspaceRootPath = nil
        } else {
            let root = draft.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            if root.isEmpty {
                workspaceRootPath = nil
            } else {
                try WorkspaceDomainValidation.requireAbsolutePath(root, field: "MCP workspace root")
                workspaceRootPath = root
            }
        }
    }

    /// A command bound to this Mac by its argument vector, with nothing to
    /// sign in to: how Agent Tooling's own connection is recorded.
    ///
    /// Nothing is parsed from a pasted line, so a path with a space in it
    /// stays one argument, and the vector goes to this Mac's binding exactly
    /// as given. It is held to the same rules as a pasted command: no control
    /// characters, nothing credential-shaped, within the size limits.
    /// `ConnectAgentToolingCommand` records the connection through it.
    init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID = ArtifactID(),
        displayName: String,
        stdioCommand: [String]
    ) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        try WorkspaceDomainValidation.requireText(name, field: "connection display name", maximum: 512)
        guard let identifier = try? WorkspaceLibrary.normalizedIdentifier(name) else {
            throw ManagedMCPServerIntakeError.invalidConnectionName(name)
        }
        try MCPDefinitionValidator.validateCommandArguments(stdioCommand)
        guard let executable = stdioCommand.first else { throw MCPDefinitionValidationError.emptyCommand }

        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.displayName = name
        declaredName = identifier
        connection = .deviceBound(transport: .stdio)
        destination = .stdio(executable: executable, arguments: Array(stdioCommand.dropFirst()))
        credentialRequirementNames = []
        authenticationRequirement = .none
        workspaceRootPath = nil
    }

    /// Whether `declaredName` is the name Agent Tooling's own connection goes
    /// by. A connection a person pastes or adds from a catalog under it would
    /// read as that connection: left out of the library and labelled as
    /// Agent Tooling's in each app. Only Let your apps ask records it.
    public static func isReservedName(_ declaredName: String) -> Bool {
        declaredName.compare(AgentToolingConnection.declaredName, options: .caseInsensitive) == .orderedSame
    }

    /// This command, refused when it would record a connection under the
    /// name Agent Tooling's own connection goes by (`isReservedName`). What a
    /// person pastes or adds from a catalog goes through this; setup's own
    /// command does not.
    public func refusingReservedName() throws -> Self {
        guard !Self.isReservedName(declaredName) else { throw ManagedMCPServerIntakeError.reservedName(declaredName) }
        return self
    }

    // MARK: - The contract's split

    private struct Split {
        let connection: PortableMCPConnection
        let destination: DeviceMCPDestination?
    }

    private static func split(
        _ validated: ValidatedMCPDestination, transport: MCPTransport
    ) throws -> Split {
        switch transport {
        case .stdio:
            // The argument vector is preserved exactly as parsed. Re-quoting it
            // for storage is how an argument containing a space becomes two.
            guard let executable = validated.command.first else {
                throw MCPDefinitionValidationError.emptyCommand
            }
            return .init(
                connection: .deviceBound(transport: .stdio),
                destination: .stdio(executable: executable, arguments: Array(validated.command.dropFirst())))
        case .http:
            guard !SensitiveValueRedactor.containsCredentialValue(in: validated.endpoint) else {
                throw MCPDefinitionValidationError.sensitiveHTTPURL
            }
            // The portable rule is the document's own, asked here so the answer
            // is the same on every Mac rather than a caller's choice.
            let isPortable =
                (try? WorkspaceMCPDefinitionValidation.validateURL(
                    validated.endpoint, portable: true)) != nil
            return isPortable
                ? .init(connection: .remoteHTTPS(url: validated.endpoint), destination: nil)
                : .init(
                    connection: .deviceBound(transport: .http),
                    destination: .httpURL(validated.endpoint))
        }
    }

    // MARK: - Credential requirements

    /// Names only, deduplicated and sorted. A name that fails the grammar the
    /// device binding enforces, or that reads as a value rather than a name, is
    /// refused with the name quoted; other legacy names require review.
    private static func recordableCredentialNames(_ names: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard name.utf8.count <= 256,
                name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
                !SensitiveValueRedactor.containsCredentialValue(in: name)
            else { throw ManagedMCPServerIntakeError.invalidCredentialName(name) }
            if seen.insert(name).inserted { result.append(name) }
        }
        guard result.count <= 256 else {
            throw WorkspaceDomainValidationError.invalidField("MCP credential requirement names")
        }
        return result.sorted()
    }

    /// What setting the connection up requires, never a claim that it is
    /// satisfied. A paste that dropped credential names and a person who chose
    /// nothing else leaves an environment requirement rather than nothing.
    private static func requirement(
        _ authentication: String, credentialNames: [String]
    ) -> MCPAuthenticationRequirement {
        switch authentication.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "oauth": return .oauth
        case "api key", "apikey", "api-key": return .apiKey
        case "doppler": return .doppler
        default: return credentialNames.isEmpty ? .none : .environment
        }
    }

    // MARK: - Identity

    func inputDigest() -> String {
        var fields = [
            "managed-mcp.intake.v1",
            expectedRevisionID.rawValue.uuidString.lowercased(),
            idempotencyKey.rawValue.uuidString.lowercased(),
            artifactID.rawValue.uuidString.lowercased(),
            displayName, declaredName,
            authenticationRequirement.rawValue,
            workspaceRootPath ?? "",
        ]
        switch connection {
        case .remoteHTTPS(let url): fields += ["remoteHTTPS", url]
        case .deviceBound(let transport): fields += ["deviceBound", transport.rawValue]
        }
        switch destination {
        case .httpURL(let url): fields += ["httpURL", url]
        case .stdio(let executable, let arguments): fields += ["stdio", executable] + arguments
        case nil: fields.append("noDestination")
        }
        fields += credentialRequirementNames
        return framedDigest(fields: fields)
    }

    // MARK: - The transaction's two halves

    /// The artifact and its shared definition, which only exist together: a
    /// standalone personal `mcpServer` without a definition fails validation
    /// inside the same transaction, so neither half can land alone.
    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        guard document.mcpDefinitions != nil else {
            // Schema 1 and 2 have nowhere to put a definition, and an artifact
            // written without one would be a connection with no address.
            throw WorkspaceDomainValidationError.unsupportedVersion(document.schemaVersion)
        }
        guard !document.tombstones.contains(where: { $0.artifactID == artifactID }) else {
            throw ManagedMCPServerIntakeError.previouslyRemoved
        }
        guard !document.artifacts.contains(where: { $0.identity.id == artifactID }),
            document.mcpDefinitions?.contains(where: { $0.artifactID == artifactID }) != true
        else { throw ManagedMCPServerIntakeError.identityCollision }
        // Two rows with one name is what breaks a client file, and the person
        // reading this screen is the only one who can say which they meant.
        guard
            !document.artifacts.contains(where: {
                $0.identity.kind == .mcpServer
                    && $0.declaredName?.compare(declaredName, options: .caseInsensitive) == .orderedSame
            })
        else { throw ManagedMCPServerIntakeError.alreadyManaged(declaredName) }

        document.artifacts.append(
            .init(
                identity: .init(id: artifactID, kind: .mcpServer, displayName: displayName),
                authority: .centralPersonal,
                declaredName: declaredName))
        document.mcpDefinitions?.append(.init(artifactID: artifactID, connection: connection))
        return [artifactID]
    }

    /// This Mac's own half: the address or argument vector for a device-bound
    /// connection, the credential names it needs and the project folder it is
    /// scoped to. None of it becomes portable bytes.
    func bind(_ device: inout DeviceWorkspaceState) throws {
        guard device.mcpBindings != nil else {
            throw WorkspaceDomainValidationError.unsupportedVersion(device.schemaVersion)
        }
        guard device.mcpBindings?.contains(where: { $0.artifactID == artifactID }) != true else {
            throw ManagedMCPServerIntakeError.identityCollision
        }
        device.mcpBindings?.append(
            .init(
                artifactID: artifactID,
                destination: destination,
                credentialRequirementNames: credentialRequirementNames,
                authenticationRequirement: authenticationRequirement,
                workspaceRootPath: workspaceRootPath))
    }
}
