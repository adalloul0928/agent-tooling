import CryptoKit
import Foundation

public enum WorkspaceMigrationNativePlacementIntakeError: Error, Equatable, Sendable {
    case invalidProject
    case duplicateProjectID
    case duplicateProjectRoot
}

/// Reviews device placement evidence for native package roots referenced by the
/// active legacy configuration. Observation paths remain evidence only and are
/// never interpreted as project roots.
public struct WorkspaceMigrationNativePlacementIntake: Sendable {
    public struct Candidate: Sendable, Equatable, Hashable {
        public let id: String
        public let scope: ToolingScope
        public let projectID: ArtifactID?
        public let projectName: String?
        public let rootPath: String?

        public init(
            id: String,
            scope: ToolingScope,
            projectID: ArtifactID? = nil,
            projectName: String? = nil,
            rootPath: String? = nil
        ) {
            self.id = id
            self.scope = scope
            self.projectID = projectID
            self.projectName = projectName
            self.rootPath = rootPath
        }
    }

    public struct Requirement: Sendable, Equatable, Hashable {
        public let id: String
        public let legacy: LegacyReferenceKey
        public let displayName: String
        public let client: ClientKind
        public let observedScope: ToolingScope?
        public let candidates: [Candidate]

        public init(
            id: String,
            legacy: LegacyReferenceKey,
            displayName: String,
            client: ClientKind,
            observedScope: ToolingScope?,
            candidates: [Candidate]
        ) {
            self.id = id
            self.legacy = legacy
            self.displayName = displayName
            self.client = client
            self.observedScope = observedScope
            self.candidates = candidates
        }
    }

    public let requirements: [Requirement]
    public let placements: [WorkspaceNativePluginMigrationPlacement]
    public let selections: [String: String]
    public let selectedProjectIDs: Set<ArtifactID>

    public init(
        requirements: [Requirement],
        placements: [WorkspaceNativePluginMigrationPlacement],
        selections: [String: String],
        selectedProjectIDs: Set<ArtifactID>
    ) {
        self.requirements = requirements
        self.placements = placements
        self.selections = selections
        self.selectedProjectIDs = selectedProjectIDs
    }

    public static func review(
        intake: WorkspaceMigrationIntake,
        workspaceID: WorkspaceObjectID,
        projects supplied: [WorkspaceMCPMigrationProject],
        selections requested: [String: String] = [:],
        requiringReview: Set<String> = []
    ) throws -> Self {
        try validateProjects(supplied)

        guard let configuration = try? LegacyConfigurationResolver.resolve(
            intake.snapshot,
            configuration: .personal(intake.snapshot.activeProfileID)
        ), let bindings = configuration.targetBindings else {
            return .init(requirements: [], placements: [], selections: [:], selectedProjectIDs: [])
        }
        let placementConfigurationEvidence = configurationEvidence(configuration, snapshot: intake.snapshot)

        let enabledClients = intake.snapshot.preferences.enabledClients
        let nativeChoices = Dictionary(grouping: intake.choices.filter { $0.strategy.kind == .nativePackage }, by: \.legacy)
        let nativeKeys = Set(nativeChoices.keys)
        let identities = try WorkspaceMigrationIdentity.mapping(keys: nativeKeys, workspaceID: workspaceID)
        let artifactIDs = Dictionary(uniqueKeysWithValues: identities.map {
            ($0.legacy, ArtifactID($0.objectID.rawValue))
        })
        let plugins = Dictionary(grouping: intake.snapshot.plugins) {
            LegacyReferenceKey(domain: .plugin, identifier: $0.id)
        }
        let bindingGroups = Dictionary(grouping: bindings.filter {
            $0.item.kind == .plugin && enabledClients.contains($0.client)
        }) { binding in
            BindingKey(legacy: .init(domain: .plugin, identifier: binding.item.identifier), client: binding.client)
        }

        var requirements: [Requirement] = []
        var placements: [WorkspaceNativePluginMigrationPlacement] = []
        var accepted: [String: String] = [:]
        var selectedProjectIDs = Set<ArtifactID>()

        for key in bindingGroups.keys.sorted(by: bindingOrder) {
            let requirementID = requirementID(key)
            let values = bindingGroups[key] ?? []
            let displayName = plugins[key.legacy]?.count == 1 ? plugins[key.legacy]?.first?.name ?? key.legacy.identifier
                : key.legacy.identifier

            guard values.count == 1, let binding = values.first,
                  plugins[key.legacy]?.count == 1,
                  nativeChoices[key.legacy]?.count == 1,
                  let choice = nativeChoices[key.legacy]?.first,
                  let artifactID = artifactIDs[key.legacy],
                  case let .nativePackage(routes, _) = choice.strategy,
                  validRoute(routes, for: key.client, externalPluginID: key.legacy.identifier)
            else {
                requirements.append(.init(id: requirementID, legacy: key.legacy, displayName: displayName,
                    client: key.client, observedScope: nil, candidates: []))
                continue
            }

            let evidence = observationEvidence(intake.snapshot, legacy: key.legacy, client: key.client)
            guard evidence.isComplete, let scope = evidence.scope else {
                requirements.append(.init(id: requirementID, legacy: key.legacy, displayName: displayName,
                    client: key.client, observedScope: nil, candidates: []))
                continue
            }

            let candidates: [Candidate]
            if scope == .user {
                candidates = [.init(id: candidateID(
                    intake: intake, key: key, binding: binding, routes: routes, evidence: evidence,
                    configurationEvidence: placementConfigurationEvidence, scope: .user, project: nil
                ), scope: .user)]
            } else if scope == .project || scope == .localProject {
                candidates = supplied.map { project in
                    .init(
                        id: candidateID(intake: intake, key: key, binding: binding, routes: routes,
                            evidence: evidence, configurationEvidence: placementConfigurationEvidence,
                            scope: scope, project: project),
                        scope: scope,
                        projectID: project.project.id,
                        projectName: project.project.name,
                        rootPath: project.rootPath
                    )
                }.sorted { candidateOrder($0, $1) }
            } else {
                candidates = []
            }

            let selected: Candidate?
            if scope == .user && !requiringReview.contains(requirementID) {
                selected = candidates.first
            } else if let requestedID = requested[requirementID] {
                selected = candidates.first { $0.id == requestedID }
            } else {
                selected = nil
            }
            if scope != .user || requiringReview.contains(requirementID) {
                requirements.append(.init(id: requirementID, legacy: key.legacy, displayName: displayName,
                    client: key.client, observedScope: scope, candidates: candidates))
            }
            guard let selected else { continue }
            placements.append(.init(artifactID: artifactID, client: key.client, scope: selected.scope,
                logicalProjectID: selected.projectID))
            if scope != .user || requiringReview.contains(requirementID) {
                accepted[requirementID] = selected.id
            }
            if let projectID = selected.projectID { selectedProjectIDs.insert(projectID) }
        }

        return .init(
            requirements: requirements.sorted(by: requirementOrder),
            placements: placements.sorted(by: placementOrder),
            selections: accepted,
            selectedProjectIDs: selectedProjectIDs
        )
    }
}

private extension WorkspaceMigrationNativePlacementIntake {
    struct BindingKey: Hashable {
        let legacy: LegacyReferenceKey
        let client: ClientKind
    }

    struct ObservationEvidence {
        let scope: ToolingScope?
        let encodedFields: [String]
        let isComplete: Bool
    }

    struct ConfigurationEvidence {
        let encodedFields: [String]
    }

    static func validateProjects(_ projects: [WorkspaceMCPMigrationProject]) throws {
        var ids = Set<ArtifactID>()
        var roots = Set<String>()
        for project in projects {
            do {
                try WorkspaceDomainValidation.requireAbsolutePath(project.rootPath, field: "native placement project root")
                try WorkspaceDomainValidation.requireText(project.project.name, field: "native placement project name", maximum: 256)
            } catch {
                throw WorkspaceMigrationNativePlacementIntakeError.invalidProject
            }
            guard project.project.name == project.project.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !project.project.name.isEmpty else {
                throw WorkspaceMigrationNativePlacementIntakeError.invalidProject
            }
            guard ids.insert(project.project.id).inserted else {
                throw WorkspaceMigrationNativePlacementIntakeError.duplicateProjectID
            }
            guard roots.insert(project.rootPath).inserted else {
                throw WorkspaceMigrationNativePlacementIntakeError.duplicateProjectRoot
            }
        }
    }

    static func validRoute(_ routes: [NativePackageRoute], for client: ClientKind, externalPluginID: String) -> Bool {
        let matching = routes.filter { $0.client == client }
        guard matching.count == 1, let route = matching.first,
              route.externalPluginID == externalPluginID,
              !route.externalPluginID.isEmpty, route.externalPluginID.count <= 512,
              !route.externalPluginID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Set(routes.map(\.client)).count == routes.count else { return false }
        return true
    }

    static func observationEvidence(
        _ snapshot: WorkspaceSnapshot,
        legacy: LegacyReferenceKey,
        client: ClientKind
    ) -> ObservationEvidence {
        let relevant = snapshot.targetObservations.filter {
            $0.surface.client == client && $0.discoveredPlugins.contains(legacy.identifier)
        }
        let matching = relevant.compactMap { observation -> (ToolingScope?, [String])? in
            guard observation.surface.client == client,
                  observation.discoveredPlugins.contains(legacy.identifier),
                  let metadata = observation.pluginMetadata[legacy.identifier] else { return nil }
            let supportedScope = observedScope(metadata.scope)
            var fields = [
                observation.surface.rawValue, metadata.name, metadata.source, metadata.scope,
                metadata.revision.map { "s" + String($0.utf8.count) + ":" + $0 } ?? "n",
                metadata.enabled ? "true" : "false",
            ]
            let skillIDs = metadata.skillIDs.sorted()
            fields.append("skills:" + String(skillIDs.count))
            fields += skillIDs
            let serverIDs = metadata.mcpServerIDs.sorted()
            fields.append("mcps:" + String(serverIDs.count))
            fields += serverIDs
            return (supportedScope, fields)
        }
        let scopes = Set(matching.compactMap(\.0))
        let complete = !relevant.isEmpty && matching.count == relevant.count
            && matching.allSatisfy { $0.0 != nil } && scopes.count == 1
        return .init(scope: complete ? scopes.first : nil,
                     encodedFields: matching.map(\.1).sorted(by: { framed($0) < framed($1) }).flatMap { $0 },
                     isComplete: complete)
    }

    static func requirementID(_ key: BindingKey) -> String {
        "native-placement|" + framed([key.legacy.domain.rawValue, key.legacy.identifier,
            key.legacy.ownerPolicyID ?? "", key.client.rawValue])
    }

    /// The legacy Claude inventory capitalizes native scope tokens. Preserve
    /// those original bytes in evidence while interpreting the supported tokens.
    static func observedScope(_ value: String) -> ToolingScope? {
        switch value {
        case "user", "User", "This Mac": .user
        case "project", "Project": .project
        case "local", "Local", "localProject", "This project only": .localProject
        default: nil
        }
    }

    static func candidateID(
        intake: WorkspaceMigrationIntake,
        key: BindingKey,
        binding: OnboardingTargetBinding,
        routes: [NativePackageRoute],
        evidence: ObservationEvidence,
        configurationEvidence: ConfigurationEvidence,
        scope: ToolingScope,
        project: WorkspaceMCPMigrationProject?
    ) -> String {
        var fields = [
            intake.snapshot.activeProfileID,
            key.legacy.domain.rawValue, key.legacy.identifier, key.client.rawValue,
            binding.enabled.map { $0 ? "true" : "false" } ?? "nil", scope.rawValue,
        ]
        fields += routes.sorted { routeOrder($0, $1) }.flatMap { [$0.client.rawValue, $0.externalPluginID] }
        fields += evidence.encodedFields
        fields += configurationEvidence.encodedFields
        fields += [project?.project.id.rawValue.uuidString.lowercased() ?? "",
                   project?.project.name ?? "", project?.rootPath ?? ""]
        let digest = SHA256.hash(data: Data(("agent-tooling.native-placement-candidate.v1\0" + framed(fields)).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func configurationEvidence(
        _ resolution: LegacyConfigurationResolution,
        snapshot: WorkspaceSnapshot
    ) -> ConfigurationEvidence {
        let profiles = resolution.contributingIdentities.compactMap { identity -> (LegacyConfigurationIdentity, ToolingProfile)? in
            switch identity {
            case .personal(let id):
                guard let profile = snapshot.profiles.first(where: { $0.id == id }) else { return nil }
                return (identity, profile)
            case .policy(let policyID, let profileID):
                guard let policy = snapshot.managedPolicies.first(where: { $0.id == policyID }),
                      let profile = policy.profiles.first(where: { $0.id == profileID }) else { return nil }
                return (identity, profile)
            }
        }
        var fields = ["configuration-chain", String(profiles.count)]
        for (identity, profile) in profiles {
            fields += identityFields(identity)
            fields += [optionalField(profile.inheritedFrom), profile.scope.rawValue, optionalField(profile.projectRoot)]
        }
        fields.append("binding-origin")
        if let origin = profiles.reversed().first(where: { $0.1.targetBindings != nil })?.0 {
            fields += identityFields(origin)
        } else {
            fields.append("none")
        }
        return .init(encodedFields: fields)
    }

    static func identityFields(_ identity: LegacyConfigurationIdentity) -> [String] {
        switch identity {
        case .personal(let id): ["personal", id]
        case .policy(let policyID, let profileID): ["policy", policyID, profileID]
        }
    }

    static func optionalField(_ value: String?) -> String {
        value.map { "s" + String($0.utf8.count) + ":" + $0 } ?? "n"
    }

    static func framed(_ fields: [String]) -> String {
        fields.map {
            let value = $0.precomposedStringWithCanonicalMapping
            return String(value.utf8.count) + ":" + value
        }.joined(separator: "|")
    }

    static func bindingOrder(_ lhs: BindingKey, _ rhs: BindingKey) -> Bool {
        let left = [lhs.legacy.identifier, lhs.client.rawValue]
        let right = [rhs.legacy.identifier, rhs.client.rawValue]
        return left.lexicographicallyPrecedes(right)
    }

    static func requirementOrder(_ lhs: Requirement, _ rhs: Requirement) -> Bool { lhs.id < rhs.id }
    static func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        [lhs.projectName ?? "", lhs.rootPath ?? "", lhs.id].lexicographicallyPrecedes(
            [rhs.projectName ?? "", rhs.rootPath ?? "", rhs.id]
        )
    }
    static func routeOrder(_ lhs: NativePackageRoute, _ rhs: NativePackageRoute) -> Bool {
        [lhs.client.rawValue, lhs.externalPluginID].lexicographicallyPrecedes([rhs.client.rawValue, rhs.externalPluginID])
    }
    static func placementOrder(
        _ lhs: WorkspaceNativePluginMigrationPlacement,
        _ rhs: WorkspaceNativePluginMigrationPlacement
    ) -> Bool {
        [lhs.artifactID.rawValue.uuidString, lhs.client.rawValue, lhs.scope.rawValue,
         lhs.logicalProjectID?.rawValue.uuidString ?? ""].lexicographicallyPrecedes(
            [rhs.artifactID.rawValue.uuidString, rhs.client.rawValue, rhs.scope.rawValue,
             rhs.logicalProjectID?.rawValue.uuidString ?? ""]
        )
    }
}
