import CryptoKit
import Foundation

/// Converts only the legacy managed-MCP rows already called out by migration
/// intake into exact, current-device resolution records. It never promotes a
/// device endpoint into a portable endpoint and leaves project-scoped servers
/// for an explicit logical-project review.
public struct WorkspaceManagedMCPMigrationIntake: Sendable {
    public struct Issue: Sendable, Equatable, Hashable {
        public enum Reason: Sendable, Equatable, Hashable {
            case invalidDefinition
            case invalidAuthentication
            case invalidCredentials
            case invalidScope
            case ambiguousClients
            case needsProjectMapping
            case invalidIdentity
        }

        public let legacy: LegacyReferenceKey
        public let reason: Reason

        public init(legacy: LegacyReferenceKey, reason: Reason) {
            self.legacy = legacy
            self.reason = reason
        }
    }

    public let intake: WorkspaceMigrationIntake
    public let resolutions: [WorkspaceManagedMCPMigrationResolution]
    public let issues: [Issue]
    public let projects: [WorkspaceMCPMigrationProject]
    public let configurationProjects: [LegacyReferenceKey: ArtifactID]

    public static func review(
        intake: WorkspaceMigrationIntake,
        context: WorkspaceMigrationContext,
        projects: [WorkspaceMCPMigrationProject] = []
    ) throws -> Self {
        let projectReview = try WorkspaceMigrationProjectIntake.review(intake: intake, projects: projects)
        let projectByRoot = Dictionary(uniqueKeysWithValues: projectReview.projects.map { ($0.rootPath, $0) })
        let requested = intake.issues.filter { $0.reason == .managedConnection }.map(\.legacy)
        guard !requested.isEmpty else {
            return .init(intake: intake, resolutions: [], issues: [], projects: projectReview.projects, configurationProjects: projectReview.configurationProjects)
        }

        let requestedGroups = Dictionary(grouping: requested, by: { $0 })
        let bundledChildren = Set(intake.choices.flatMap { choice -> [LegacyReferenceKey] in
            guard case let .nativePackage(_, children) = choice.strategy else { return [] }
            return children.map(\.legacy)
        })
        let serversByKey = Dictionary(grouping: intake.snapshot.mcpServers) {
            LegacyReferenceKey(domain: .mcpServer, identifier: $0.id)
        }
        let keys = Set(requested).subtracting(bundledChildren)
        let identities: [LegacyReferenceKey: ArtifactID]
        do {
            var values: [LegacyReferenceKey: ArtifactID] = [:]
            for entry in try WorkspaceMigrationIdentity.mapping(keys: keys, workspaceID: context.workspaceID) {
                guard values[entry.legacy] == nil else { throw IntakeError.invalidIdentity }
                values[entry.legacy] = ArtifactID(entry.objectID.rawValue)
            }
            identities = values
        } catch {
            let issues = keys.sorted(by: keyOrder).map { Issue(legacy: $0, reason: .invalidIdentity) }
            return .init(intake: intake, resolutions: [], issues: issues, projects: projectReview.projects, configurationProjects: projectReview.configurationProjects)
        }

        var resolutions: [WorkspaceManagedMCPMigrationResolution] = []
        var issues: [Issue] = []
        var resolved = Set<LegacyReferenceKey>()
        var assignmentIDs = Set<WorkspaceObjectID>()

        for key in keys.sorted(by: keyOrder) {
            guard requestedGroups[key]?.count == 1,
                  let matches = serversByKey[key], matches.count == 1,
                  let server = matches.first,
                  server.isManagedDefinition,
                  let artifactID = identities[key] else {
                issues.append(.init(legacy: key, reason: .invalidIdentity))
                continue
            }

            do {
                let resolution = try makeResolution(
                    server: server,
                    artifactID: artifactID,
                    context: context,
                    projectsByRoot: projectByRoot
                )
                let ids = resolution.assignments.map(\.id)
                guard Set(ids).count == ids.count,
                      assignmentIDs.isDisjoint(with: Set(ids)) else {
                    throw IntakeError.invalidIdentity
                }
                try WorkspaceManagedMCPMigrationValidation.validate(
                    resolution, server: server, artifactID: artifactID, deviceID: context.deviceID
                )
                assignmentIDs.formUnion(ids)
                resolutions.append(resolution)
                resolved.insert(key)
            } catch let error as IntakeError {
                issues.append(.init(legacy: key, reason: error.reason))
            } catch {
                issues.append(.init(legacy: key, reason: .invalidDefinition))
            }
        }

        let retained = intake.issues.filter { issue in
            issue.reason != .managedConnection || !resolved.contains(issue.legacy)
        }
        return .init(
            intake: .init(choices: intake.choices, issues: retained, snapshot: intake.snapshot),
            resolutions: resolutions.sorted { $0.legacyServerID < $1.legacyServerID },
            issues: issues.sorted { lhs, rhs in
                keyOrder(lhs.legacy, rhs.legacy) || (lhs.legacy == rhs.legacy && reasonOrder(lhs.reason) < reasonOrder(rhs.reason))
            },
            projects: projectReview.projects,
            configurationProjects: projectReview.configurationProjects
        )
    }
}

private extension WorkspaceManagedMCPMigrationIntake {
    enum IntakeError: Error {
        case invalidDefinition
        case invalidAuthentication
        case invalidCredentials
        case invalidScope
        case ambiguousClients
        case needsProjectMapping
        case invalidIdentity

        var reason: Issue.Reason {
            switch self {
            case .invalidDefinition: .invalidDefinition
            case .invalidAuthentication: .invalidAuthentication
            case .invalidCredentials: .invalidCredentials
            case .invalidScope: .invalidScope
            case .ambiguousClients: .ambiguousClients
            case .needsProjectMapping: .needsProjectMapping
            case .invalidIdentity: .invalidIdentity
            }
        }
    }

    static func makeResolution(
        server: MCPServer,
        artifactID: ArtifactID,
        context: WorkspaceMigrationContext,
        projectsByRoot: [String: WorkspaceMCPMigrationProject]
    ) throws -> WorkspaceManagedMCPMigrationResolution {
        guard Set(server.clients.map(\.client)).count == server.clients.count else {
            throw IntakeError.ambiguousClients
        }
        guard Set(server.secretNames).count == server.secretNames.count else {
            throw IntakeError.invalidCredentials
        }
        let authentication = try authenticationRequirement(server.authentication)
        do {
            try DeviceMCPDefinitionBinding(artifactID: artifactID,
                credentialRequirementNames: server.secretNames,
                authenticationRequirement: authentication).validate()
        } catch { throw IntakeError.invalidCredentials }
        let scope = try migrationScope(server.scope)
        let project: WorkspaceMCPMigrationProject?
        if scope == .project || scope == .localProject {
            guard let root = server.projectRoot, let mapped = projectsByRoot[root] else {
                throw IntakeError.needsProjectMapping
            }
            project = mapped
        } else {
            project = nil
        }
        let destination: ValidatedMCPDestination
        do {
            destination = try MCPDefinitionValidator.validate(server.endpoint, transport: server.transport)
        } catch {
            throw IntakeError.invalidDefinition
        }

        let deviceDestination: DeviceMCPDestination
        switch server.transport {
        case .http:
            deviceDestination = .httpURL(destination.endpoint)
        case .stdio:
            guard let executable = destination.command.first else { throw IntakeError.invalidDefinition }
            deviceDestination = .stdio(executable: executable, arguments: Array(destination.command.dropFirst()))
        }
        let workspaceRoot: String?
        switch scope {
        case .workspace:
            guard let root = server.projectRoot else { throw IntakeError.invalidScope }
            do { try WorkspaceDomainValidation.requireAbsolutePath(root, field: "MCP workspace root") }
            catch { throw IntakeError.invalidScope }
            workspaceRoot = root
        case .user, .managed, .account, .session:
            guard server.projectRoot == nil else { throw IntakeError.invalidScope }
            workspaceRoot = nil
        case .project, .localProject:
            guard project != nil else { throw IntakeError.needsProjectMapping }
            workspaceRoot = nil
        }

        let binding = DeviceMCPDefinitionBinding(
            artifactID: artifactID,
            destination: deviceDestination,
            credentialRequirementNames: server.secretNames,
            authenticationRequirement: authentication,
            workspaceRootPath: workspaceRoot
        )
        do { try binding.validate() }
        catch { throw IntakeError.invalidDefinition }
        let assignments = try server.clients.sorted { $0.client.rawValue < $1.client.rawValue }.map { client in
            AssignmentContribution(
                id: try assignmentID(
                    workspaceID: context.workspaceID,
                    deviceID: context.deviceID,
                    artifactID: artifactID,
                    scope: scope,
                    surface: surface(for: client.client)
                ),
                artifactID: artifactID,
                destination: .init(surface: surface(for: client.client), scope: scope,
                                   logicalProjectID: project?.project.id, deviceIDs: [context.deviceID]),
                reason: .manual,
                desiredPresence: true,
                desiredEnabled: nil
            )
        }
        return .init(
            legacyServerID: server.id,
            definition: .init(artifactID: artifactID, connection: .deviceBound(transport: server.transport)),
            deviceBinding: binding,
            assignments: assignments,
            project: project
        )
    }

    static func authenticationRequirement(_ value: String) throws -> MCPAuthenticationRequirement {
        switch value {
        case "None": .none
        case "OAuth": .oauth
        case "API key": .apiKey
        case "Doppler": .doppler
        case "Environment": .environment
        default: throw IntakeError.invalidAuthentication
        }
    }

    static func migrationScope(_ value: String) throws -> ToolingScope {
        guard let scope = ToolingScope.allCases.first(where: { $0.rawValue == value || $0.displayName == value }),
              ConfigurationValidator.editableScopes.contains(scope) else {
            throw IntakeError.invalidScope
        }
        return scope
    }

    static func surface(for client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    static func assignmentID(
        workspaceID: WorkspaceObjectID,
        deviceID: WorkspaceObjectID,
        artifactID: ArtifactID,
        scope: ToolingScope,
        surface: TargetSurface
    ) throws -> WorkspaceObjectID {
        var payload = Data("agent-tooling.managed-mcp-migration-assignment.v1\n".utf8)
        for field in [
            workspaceID.rawValue.uuidString.lowercased(),
            deviceID.rawValue.uuidString.lowercased(),
            artifactID.rawValue.uuidString.lowercased(),
            scope.rawValue,
            surface.rawValue,
        ] {
            let bytes = Data(field.precomposedStringWithCanonicalMapping.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(bytes)
        }
        var digest = Array(SHA256.hash(data: payload).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x80
        digest[8] = (digest[8] & 0x3f) | 0x80
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        guard let uuid = UUID(uuidString: ranges.map {
            String(hex.dropFirst($0.lowerBound).prefix($0.count))
        }.joined(separator: "-")) else {
            throw IntakeError.invalidIdentity
        }
        return WorkspaceObjectID(uuid)
    }

    static func reasonOrder(_ reason: Issue.Reason) -> Int {
        switch reason {
        case .invalidDefinition: 0
        case .invalidAuthentication: 1
        case .invalidCredentials: 2
        case .invalidScope: 3
        case .ambiguousClients: 4
        case .needsProjectMapping: 5
        case .invalidIdentity: 6
        }
    }

    static func keyOrder(_ lhs: LegacyReferenceKey, _ rhs: LegacyReferenceKey) -> Bool {
        if lhs.domain != rhs.domain { return lhs.domain.rawValue < rhs.domain.rawValue }
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return switch (lhs.ownerPolicyID, rhs.ownerPolicyID) {
        case (nil, .some): true
        case (.some(let lhs), .some(let rhs)): lhs < rhs
        default: false
        }
    }
}
