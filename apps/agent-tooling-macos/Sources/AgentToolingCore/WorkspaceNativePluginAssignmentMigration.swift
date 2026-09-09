import CryptoKit
import Foundation

public struct WorkspaceNativePluginMigrationPlacement: Codable, Hashable, Sendable {
    public var artifactID: ArtifactID
    public var client: ClientKind
    public var scope: ToolingScope
    public var logicalProjectID: ArtifactID?

    public init(artifactID: ArtifactID, client: ClientKind, scope: ToolingScope, logicalProjectID: ArtifactID? = nil) {
        self.artifactID = artifactID
        self.client = client
        self.scope = scope
        self.logicalProjectID = logicalProjectID
    }
}

public enum WorkspaceNativePluginAssignmentMigrationIssueKind: String, Hashable, Sendable {
    case missingActiveConfiguration
    case unresolvedPluginBinding
    case unsupportedArtifact
    case nativeChild
    case missingPlacement
    case duplicatePlacement
    case unusedPlacement
    case invalidScope
    case invalidProject
    case missingNativeRoute
    case ambiguousNativeRoute
    case invalidNativeRoute
    case existingAssignmentConflict
    case invalidProposedDocument
}

public struct WorkspaceNativePluginAssignmentMigrationIssue: Hashable, Sendable {
    public let kind: WorkspaceNativePluginAssignmentMigrationIssueKind
    public let artifactID: ArtifactID?
    public let client: ClientKind?

    public init(kind: WorkspaceNativePluginAssignmentMigrationIssueKind, artifactID: ArtifactID? = nil, client: ClientKind? = nil) {
        self.kind = kind
        self.artifactID = artifactID
        self.client = client
    }
}

public struct WorkspaceNativePluginAssignmentMigrationPreview: Sendable {
    public let proposals: [AssignmentContribution]
    public let issues: [WorkspaceNativePluginAssignmentMigrationIssue]
    public var canMigrate: Bool { issues.isEmpty }
}

private struct WorkspaceNativePluginPlacementKey: Hashable {
    let artifactID: ArtifactID
    let client: ClientKind
}

/// Converts only explicit, reviewed native-plugin placements. It does not use
/// observations to invent desired state and never constructs a native command.
public enum WorkspaceNativePluginAssignmentMigration {
    public static func preview(
        candidate: WorkspaceMigrationCandidate,
        placements: [WorkspaceNativePluginMigrationPlacement]
    ) throws -> WorkspaceNativePluginAssignmentMigrationPreview {
        let document = candidate.document
        let device = candidate.device
        try document.validateStructure()
        try device.validateStructure(against: document)
        guard let configurationID = device.configurationState?.activeConfigurationOverrideID
                ?? document.configurationState?.defaultConfigurationID else {
            return .init(proposals: [], issues: placements.isEmpty ? [] : [.init(kind: .missingActiveConfiguration)])
        }
        let configuration = try WorkspaceConfigurationResolver.resolve(document: document, configurationID: configurationID)
        guard let bindings = configuration.targetBindings else {
            return .init(proposals: [], issues: placements.isEmpty ? [] : placements.map {
                .init(kind: .unusedPlacement, artifactID: $0.artifactID, client: $0.client)
            })
        }

        let enabledClients = Set(device.applicationState?.preferences.enabledClients
            ?? Array(candidate.legacySnapshot.preferences.enabledClients))
        let artifacts = Dictionary(uniqueKeysWithValues: document.artifacts.map { ($0.identity.id, $0) })
        let roots = Set((device.projectRoots ?? []).map(\.projectID))
        let placementGroups = Dictionary(grouping: placements) {
            WorkspaceNativePluginPlacementKey(artifactID: $0.artifactID, client: $0.client)
        }
        var used = Set<WorkspaceNativePluginMigrationPlacement>()
        var issues: [WorkspaceNativePluginAssignmentMigrationIssue] = []
        var proposals: [AssignmentContribution] = []

        for binding in bindings.sorted(by: { bindingKey($0) < bindingKey($1) }) where binding.item.legacy.domain == .plugin {
            // The portable binding remains intact, but this migration only creates
            // device-local assignments for clients enabled on the current device.
            guard enabledClients.contains(binding.client) else { continue }
            guard case .artifact(let artifactID) = binding.item.resolution else {
                issues.append(.init(kind: .unresolvedPluginBinding, client: binding.client))
                continue
            }
            guard let artifact = artifacts[artifactID] else {
                issues.append(.init(kind: .unsupportedArtifact, artifactID: artifactID, client: binding.client))
                continue
            }
            guard artifact.identity.parentPackageID == nil else {
                issues.append(.init(kind: .nativeChild, artifactID: artifactID, client: binding.client))
                continue
            }
            guard artifact.identity.kind == .nativePlugin, artifact.authority == .nativeOwned else {
                issues.append(.init(kind: .unsupportedArtifact, artifactID: artifactID, client: binding.client))
                continue
            }
            let key = WorkspaceNativePluginPlacementKey(artifactID: artifactID, client: binding.client)
            guard let matching = placementGroups[key] else {
                issues.append(.init(kind: .missingPlacement, artifactID: artifactID, client: binding.client))
                continue
            }
            guard matching.count == 1, let placement = matching.first else {
                used.formUnion(matching)
                issues.append(.init(kind: .duplicatePlacement, artifactID: artifactID, client: binding.client))
                continue
            }
            used.insert(placement)
            guard placement.scope == .user || placement.scope == .project || placement.scope == .localProject else {
                issues.append(.init(kind: .invalidScope, artifactID: artifactID, client: binding.client))
                continue
            }
            if placement.scope == .user {
                guard placement.logicalProjectID == nil else {
                    issues.append(.init(kind: .invalidProject, artifactID: artifactID, client: binding.client))
                    continue
                }
            } else {
                guard let projectID = placement.logicalProjectID, roots.contains(projectID) else {
                    issues.append(.init(kind: .invalidProject, artifactID: artifactID, client: binding.client))
                    continue
                }
            }
            let routes = artifact.nativeRoutes.filter { $0.client == binding.client }
            guard routes.count == 1 else {
                issues.append(.init(kind: routes.isEmpty ? .missingNativeRoute : .ambiguousNativeRoute,
                    artifactID: artifactID, client: binding.client))
                continue
            }
            guard let externalPluginID = routes.first?.externalPluginID, !externalPluginID.isEmpty,
                  externalPluginID.count <= 512,
                  !externalPluginID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                issues.append(.init(kind: .invalidNativeRoute, artifactID: artifactID, client: binding.client))
                continue
            }
            let assignment = AssignmentContribution(
                id: assignmentID(workspaceID: document.workspaceID, deviceID: device.deviceID,
                    configurationID: configurationID, placement: placement),
                artifactID: artifactID,
                destination: .init(surface: surface(for: binding.client), scope: placement.scope,
                    logicalProjectID: placement.logicalProjectID, deviceIDs: [device.deviceID]),
                reason: .onboarding(configurationID: configurationID),
                desiredEnabled: binding.enabled)
            if let existing = document.assignments.first(where: { $0.id == assignment.id }) {
                if existing != assignment {
                    issues.append(.init(kind: .existingAssignmentConflict, artifactID: artifactID, client: binding.client))
                }
                continue
            }
            proposals.append(assignment)
        }

        for placement in placements where !used.contains(placement) {
            issues.append(.init(kind: .unusedPlacement, artifactID: placement.artifactID, client: placement.client))
        }
        var proposed = document
        proposed.assignments += proposals
        do { try proposed.validateStructure() }
        catch { issues.append(.init(kind: .invalidProposedDocument)) }
        return .init(proposals: proposals.sorted { $0.id < $1.id }, issues: issues.sorted(by: issueOrder))
    }

    private static func surface(for client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    private static func assignmentID(
        workspaceID: WorkspaceObjectID, deviceID: WorkspaceObjectID, configurationID: WorkspaceObjectID,
        placement: WorkspaceNativePluginMigrationPlacement
    ) -> WorkspaceObjectID {
        var bytes = Data("agent-tooling.legacy-native-plugin-assignment.v1\n".utf8)
        for field in [workspaceID.rawValue.uuidString.lowercased(), deviceID.rawValue.uuidString.lowercased(),
            configurationID.rawValue.uuidString.lowercased(), placement.artifactID.rawValue.uuidString.lowercased(),
            placement.client.rawValue, placement.scope.rawValue, placement.logicalProjectID?.rawValue.uuidString.lowercased() ?? ""] {
            let value = Data(field.utf8)
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        var hash = Array(SHA256.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x80
        hash[8] = (hash[8] & 0x3f) | 0x80
        return WorkspaceObjectID(UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15])))
    }

    private static func bindingKey(_ value: WorkspaceConfigurationTargetBinding) -> String {
        "\(value.item.legacy.domain.rawValue)|\(value.item.legacy.identifier)|\(value.client.rawValue)"
    }

    private static func issueOrder(_ lhs: WorkspaceNativePluginAssignmentMigrationIssue,
        _ rhs: WorkspaceNativePluginAssignmentMigrationIssue) -> Bool {
        let left = [lhs.kind.rawValue, lhs.artifactID?.rawValue.uuidString ?? "", lhs.client?.rawValue ?? ""]
        let right = [rhs.kind.rawValue, rhs.artifactID?.rawValue.uuidString ?? "", rhs.client?.rawValue ?? ""]
        return left.lexicographicallyPrecedes(right)
    }
}
