import Foundation

/// Device-only evidence connecting an existing project folder to its reviewed
/// logical identity. The final configuration/device conversion must retain this
/// mapping; this preview is not a durable project enrollment.
public struct WorkspaceMCPMigrationProject: Sendable {
    public var project: LogicalProjectRecord
    public var rootPath: String
    public init(project: LogicalProjectRecord, rootPath: String) {
        self.project = project; self.rootPath = rootPath
    }
}

public struct WorkspaceManagedMCPMigrationResolution: Sendable {
    public var legacyServerID: String
    public var definition: PortableMCPDefinitionRecord
    public var deviceBinding: DeviceMCPDefinitionBinding?
    public var assignments: [AssignmentContribution]
    public var project: WorkspaceMCPMigrationProject?
    public init(legacyServerID: String, definition: PortableMCPDefinitionRecord,
                deviceBinding: DeviceMCPDefinitionBinding? = nil,
                assignments: [AssignmentContribution] = [], project: WorkspaceMCPMigrationProject? = nil) {
        self.legacyServerID = legacyServerID; self.definition = definition
        self.deviceBinding = deviceBinding; self.assignments = assignments; self.project = project
    }
}

enum WorkspaceManagedMCPMigrationValidation {
    static func validate(_ resolution: WorkspaceManagedMCPMigrationResolution,
                         server: MCPServer, artifactID: ArtifactID, deviceID: WorkspaceObjectID) throws {
        guard server.isManagedDefinition, resolution.legacyServerID == server.id,
              resolution.definition.artifactID == artifactID else { throw invalid("MCP migration identity") }
        try resolution.definition.validate()
        let legacy: ValidatedMCPDestination
        do { legacy = try MCPDefinitionValidator.validate(server.endpoint, transport: server.transport) }
        catch { throw invalid("legacy MCP definition") }
        guard resolution.definition.connection.transport == server.transport else { throw invalid("MCP migration transport") }
        if let binding = resolution.deviceBinding {
            guard binding.artifactID == artifactID else { throw invalid("MCP migration binding") }
            try WorkspaceMCPDefinitionValidation.validateDevice([binding], definitions: [resolution.definition])
        }
        guard Set(server.secretNames).count == server.secretNames.count,
              (resolution.deviceBinding?.credentialRequirementNames ?? []).sorted() == server.secretNames.sorted() else {
            throw invalid("MCP migration credential requirements")
        }
        let authentication: MCPAuthenticationRequirement
        switch server.authentication {
        case "None": authentication = .none
        case "OAuth": authentication = .oauth
        case "API key": authentication = .apiKey
        case "Doppler": authentication = .doppler
        case "Environment": authentication = .environment
        default: throw invalid("MCP migration authentication requirement")
        }
        guard (resolution.deviceBinding?.authenticationRequirement ?? .none) == authentication else {
            throw invalid("MCP migration authentication requirement")
        }
        switch resolution.definition.connection {
        case .remoteHTTPS(let url):
            guard url == legacy.endpoint else { throw invalid("MCP migration endpoint") }
        case .deviceBound:
            switch resolution.deviceBinding?.destination {
            case .httpURL(let url):
                guard server.transport == .http, url == legacy.endpoint else { throw invalid("MCP migration endpoint") }
            case .stdio(let executable, let arguments):
                guard server.transport == .stdio, [executable] + arguments == legacy.command else {
                    throw invalid("MCP migration command")
                }
            case nil: throw invalid("MCP migration device destination")
            }
        }
        guard let scope = ToolingScope.allCases.first(where: { $0.rawValue == server.scope || $0.displayName == server.scope }),
              ConfigurationValidator.editableScopes.contains(scope) else {
            throw invalid("MCP migration scope")
        }
        let projectID: ArtifactID?
        switch scope {
        case .project, .localProject:
            guard let project = resolution.project, let originalRoot = server.projectRoot,
                  project.rootPath == originalRoot else { throw invalid("MCP migration project root") }
            try WorkspaceDomainValidation.requireAbsolutePath(project.rootPath, field: "MCP project root")
            try WorkspaceDomainValidation.requireText(project.project.name, field: "MCP logical project name", maximum: 256)
            projectID = project.project.id
        case .workspace:
            guard let root = server.projectRoot, resolution.project == nil,
                  resolution.deviceBinding?.workspaceRootPath == root else { throw invalid("MCP workspace root") }
            try WorkspaceDomainValidation.requireAbsolutePath(root, field: "MCP workspace root")
            projectID = nil
        case .user, .managed, .account, .session:
            guard server.projectRoot == nil, resolution.project == nil else { throw invalid("MCP migration project scope") }
            projectID = nil
        }
        if scope != .workspace, resolution.deviceBinding?.workspaceRootPath != nil {
            throw invalid("MCP workspace root scope")
        }
        let expected = server.clients.map { surface($0.client) }
        guard Set(expected).count == expected.count,
              Set(resolution.assignments.map(\.id)).count == resolution.assignments.count,
              resolution.assignments.count == expected.count,
              Set(resolution.assignments.map(\.destination.surface)) == Set(expected) else {
            throw invalid("MCP migration target coverage")
        }
        for assignment in resolution.assignments {
            // Health and discovered installation state do not establish enabled
            // intent. Migration retains presence and leaves enablement unknown.
            guard assignment.artifactID == artifactID, assignment.desiredPresence,
                  assignment.desiredEnabled == nil, assignment.reason == .manual,
                  assignment.destination.scope == scope,
                  assignment.destination.logicalProjectID == projectID,
                  assignment.destination.deviceIDs == [deviceID] else {
                throw invalid("MCP migration assignment")
            }
        }
    }

    private static func surface(_ client: ClientKind) -> TargetSurface {
        switch client { case .claude: .claudeCode; case .codex: .codexCLI; case .gemini: .geminiCLI }
    }
    private static func invalid(_ field: String) -> WorkspaceDomainValidationError { .invalidField(field) }
}
