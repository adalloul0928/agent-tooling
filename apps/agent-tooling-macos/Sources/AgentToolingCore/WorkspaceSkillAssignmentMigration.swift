import CryptoKit
import Foundation

public enum WorkspaceSkillAssignmentMigrationIssueKind: String, Hashable, Sendable {
    case missingArtifact
    case unsupportedOwnership
    case packageChildRequiresReview
    case unsupportedScope
    case missingProjectMapping
    case projectRootMismatch
    case invalidDeploymentName
    case existingAssignmentConflict
}

public struct WorkspaceSkillAssignmentMigrationIssue: Hashable, Sendable {
    public let legacySkillID: String
    public let kind: WorkspaceSkillAssignmentMigrationIssueKind
}

public struct WorkspaceSkillAssignmentMigrationPreview: Sendable {
    /// Proposed once during migration review. These are not persisted or applied.
    public let assignments: [AssignmentContribution]
    /// Keep the existing installation name, independent of display/declared names.
    public let deploymentNames: [ArtifactID: String]
    public let issues: [WorkspaceSkillAssignmentMigrationIssue]
    public var canMigrate: Bool { issues.isEmpty }
}

/// One-time conversion of legacy standalone sync intent. The retained snapshot
/// is used only here, before migration approval. Normal assignment resolution
/// must use committed contributions, never historical DeviceInventoryState rows.
/// Native plugins and repository-linked installation updates have separate routes.
public enum WorkspaceSkillAssignmentMigration {
    public static func preview(
        candidate: WorkspaceMigrationCandidate,
        projectIDsBySkillID: [ArtifactID: ArtifactID] = [:]
    ) throws -> WorkspaceSkillAssignmentMigrationPreview {
        let document = candidate.document
        let device = candidate.device
        try document.validateStructure()
        try device.validateStructure(against: document)
        let configurationID = device.configurationState?.activeConfigurationOverrideID
            ?? document.configurationState?.defaultConfigurationID
        let configuration = try configurationID.map {
            try WorkspaceConfigurationResolver.resolve(document: document, configurationID: $0)
        }
        let bindings = configuration?.targetBindings
        let required = Set(configuration?.requiredSkills.compactMap { reference -> ArtifactID? in
            guard case .artifact(let id) = reference.resolution else { return nil }
            return id
        } ?? [])
        let enabledClients = Set(device.applicationState?.preferences.enabledClients
            ?? Array(candidate.legacySnapshot.preferences.enabledClients))
        let identities = Dictionary(uniqueKeysWithValues: (document.configurationState?.identityMap ?? []).map { ($0.legacy, $0.objectID) })
        let artifacts = Dictionary(uniqueKeysWithValues: document.artifacts.map { ($0.identity.id, $0) })
        let roots = Dictionary(uniqueKeysWithValues: (device.projectRoots ?? []).map { ($0.projectID, $0.rootPath) })
        var assignments: [AssignmentContribution] = []
        var deploymentNames: [ArtifactID: String] = [:]
        var issues: [WorkspaceSkillAssignmentMigrationIssue] = []
        for skill in candidate.legacySnapshot.skills.sorted(by: { $0.id < $1.id }) where skill.owned {
            let availableClients = Set(skill.clients.map(\.client)).intersection(enabledClients)
            guard !availableClients.isEmpty else { continue }
            func issue(_ kind: WorkspaceSkillAssignmentMigrationIssueKind) {
                issues.append(.init(legacySkillID: skill.id, kind: kind))
            }
            guard let identity = identities[.init(domain: .skill, identifier: skill.id)],
                  let artifact = artifacts[ArtifactID(identity.rawValue)], artifact.identity.kind == .skill else {
                issue(.missingArtifact); continue
            }
            let targets: Set<ClientKind>
            if let bindings {
                guard required.contains(artifact.identity.id) else { continue }
                targets = Set(bindings.filter {
                    $0.item.resolution == .artifact(artifact.identity.id) && $0.enabled == true
                }.map(\.client)).intersection(enabledClients)
            } else {
                // Preserve the old all-nil fallback even for skills not named in
                // the active configuration. Explicit [] never reaches this path.
                targets = availableClients
            }
            guard !targets.isEmpty else { continue }
            // A prior owned flag cannot overrule the reviewed package graph.
            // A mismatch is reviewable rather than silently making a child copy.
            guard artifact.identity.parentPackageID == nil else {
                issue(.packageChildRequiresReview); continue
            }
            switch artifact.authority {
            case .centralPersonal, .centralUpstream: break
            case .nativeOwned, .attachedAuthoring, .trackedOnly:
                issue(.unsupportedOwnership); continue
            }
            guard let scope = ToolingScope.allCases.first(where: { $0.displayName == skill.scope }),
                  scope == .user || scope == .project else { issue(.unsupportedScope); continue }
            let projectID: ArtifactID?
            if scope == .project {
                guard let id = projectIDsBySkillID[artifact.identity.id], let root = roots[id] else {
                    issue(.missingProjectMapping); continue
                }
                guard let rawRoot = skill.projectRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
                      rawRoot.hasPrefix("/"), URL(fileURLWithPath: rawRoot).standardizedFileURL.path
                        == URL(fileURLWithPath: root).standardizedFileURL.path else {
                    issue(.projectRootMismatch); continue
                }
                projectID = id
            } else { projectID = nil }
            do {
                // Validate one path component with the actual adapter contract.
                _ = try NativeSkillDestination.skillURL(client: .codex, skillID: skill.id,
                    homeURL: URL(fileURLWithPath: "/"), scope: .user, projectRoot: nil)
            } catch { issue(.invalidDeploymentName); continue }
            let reason: AssignmentReason
            if bindings != nil, let configurationID { reason = .onboarding(configurationID: configurationID) }
            else { reason = .manual }
            for client in targets.sorted(by: { $0.rawValue < $1.rawValue }) {
                let surface: TargetSurface
                switch client {
                case .claude: surface = .claudeCode
                case .codex: surface = .codexCLI
                case .gemini: surface = .geminiCLI
                }
                let assignment = AssignmentContribution(id: identityForAssignment(
                    workspaceID: document.workspaceID, deviceID: device.deviceID, artifactID: artifact.identity.id,
                    surface: surface, scope: scope, projectID: projectID,
                    configurationID: bindings == nil ? nil : configurationID),
                    artifactID: artifact.identity.id,
                    destination: .init(surface: surface, scope: scope, logicalProjectID: projectID, deviceIDs: [device.deviceID]),
                    reason: reason, desiredEnabled: bindings == nil ? nil : true)
                if let existing = document.assignments.first(where: { $0.id == assignment.id }) {
                    if existing != assignment { issue(.existingAssignmentConflict) }
                    continue
                }
                assignments.append(assignment)
                deploymentNames[artifact.identity.id] = skill.id
            }
        }
        // Exercise actual portable reference/ownership checks, including joins to
        // project records. Resolution and filesystem capability checks follow.
        var proposed = document
        let existingIDs = Set(proposed.assignments.map(\.id))
        proposed.assignments += assignments.filter { !existingIDs.contains($0.id) }
        try proposed.validateStructure()
        return .init(assignments: assignments.sorted { $0.id < $1.id }, deploymentNames: deploymentNames, issues: issues)
    }

    private static func identityForAssignment(
        workspaceID: WorkspaceObjectID, deviceID: WorkspaceObjectID, artifactID: ArtifactID,
        surface: TargetSurface, scope: ToolingScope, projectID: ArtifactID?, configurationID: WorkspaceObjectID?
    ) -> WorkspaceObjectID {
        var bytes = Data("agent-tooling.legacy-skill-assignment.v1\n".utf8)
        for field in [workspaceID.rawValue.uuidString.lowercased(), deviceID.rawValue.uuidString.lowercased(),
            artifactID.rawValue.uuidString.lowercased(), surface.rawValue, scope.rawValue,
            projectID?.rawValue.uuidString.lowercased() ?? "", configurationID?.rawValue.uuidString.lowercased() ?? ""] {
            let content = Data(field.utf8)
            var length = UInt64(content.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(content)
        }
        var hash = Array(SHA256.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x80
        hash[8] = (hash[8] & 0x3f) | 0x80
        return WorkspaceObjectID(UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15])))
    }
}
