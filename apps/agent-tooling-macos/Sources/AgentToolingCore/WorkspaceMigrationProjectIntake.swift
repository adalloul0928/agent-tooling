import Foundation

public enum WorkspaceMigrationProjectIntakeError: Error, Equatable, Sendable {
    case invalidProject
    case duplicateRoot
    case duplicateProjectID
    case unreferencedProject
}

/// Groups reviewed project-scoped legacy records by their exact saved local
/// root. It never resolves symlinks or chooses a logical-project identity.
public struct WorkspaceMigrationProjectIntake: Sendable {
    public struct Item: Sendable, Equatable, Hashable {
        public let legacy: LegacyReferenceKey
        public let displayName: String
        public let scope: ToolingScope
        public init(legacy: LegacyReferenceKey, displayName: String, scope: ToolingScope) {
            self.legacy = legacy; self.displayName = displayName; self.scope = scope
        }
    }

    public struct Requirement: Sendable, Equatable, Hashable {
        public let id: String
        public let rootPath: String?
        public let canMap: Bool
        public let items: [Item]
        public init(id: String, rootPath: String?, canMap: Bool, items: [Item]) {
            self.id = id; self.rootPath = rootPath; self.canMap = canMap; self.items = items
        }
    }

    public let requirements: [Requirement]
    public let projects: [WorkspaceMCPMigrationProject]
    public let configurationProjects: [LegacyReferenceKey: ArtifactID]

    public static func review(intake: WorkspaceMigrationIntake, projects supplied: [WorkspaceMCPMigrationProject]) throws -> Self {
        var candidates: [(LegacyReferenceKey, String, ToolingScope, String?)] = []
        for profile in intake.snapshot.profiles where profile.scope == .project || profile.scope == .localProject {
            candidates.append((.init(domain: .configuration, identifier: profile.id), profile.name, profile.scope, profile.projectRoot))
        }
        for policy in intake.snapshot.managedPolicies {
            for profile in policy.profiles where profile.scope == .project || profile.scope == .localProject {
                candidates.append((.init(domain: .configuration, identifier: profile.id, ownerPolicyID: policy.id), profile.name, profile.scope, profile.projectRoot))
            }
        }
        let nativeChildren = Set(intake.choices.flatMap { choice -> [LegacyReferenceKey] in
            guard case let .nativePackage(_, children) = choice.strategy else { return [] }
            return children.map(\.legacy)
        })
        let issueKeys = Set(intake.issues.filter { $0.reason == .managedConnection }.map(\.legacy)).subtracting(nativeChildren)
        let servers = Dictionary(grouping: intake.snapshot.mcpServers) { LegacyReferenceKey(domain: .mcpServer, identifier: $0.id) }
        for key in issueKeys.sorted(by: keyOrder) {
            guard let values = servers[key], values.count == 1, let server = values.first,
                  server.isManagedDefinition,
                  let scope = ToolingScope.allCases.first(where: { $0.rawValue == server.scope || $0.displayName == server.scope }),
                  scope == .project || scope == .localProject else { continue }
            candidates.append((key, server.name, scope, server.projectRoot))
        }

        guard Set(candidates.map(\.0)).count == candidates.count else {
            throw WorkspaceMigrationProjectIntakeError.invalidProject
        }
        var validRoots: [String: [Item]] = [:]
        var invalid: [Requirement] = []
        for (legacy, name, scope, root) in candidates {
            guard let root, (try? WorkspaceDomainValidation.requireAbsolutePath(root, field: "migration project root")) != nil else {
                invalid.append(.init(id: requirementID(legacy), rootPath: root, canMap: false,
                                     items: [.init(legacy: legacy, displayName: name, scope: scope)]))
                continue
            }
            validRoots[root, default: []].append(.init(legacy: legacy, displayName: name, scope: scope))
        }

        var projectByRoot: [String: WorkspaceMCPMigrationProject] = [:]
        var rootsByID: [ArtifactID: String] = [:]
        for project in supplied {
            try WorkspaceDomainValidation.requireAbsolutePath(project.rootPath, field: "migration project root")
            try WorkspaceDomainValidation.requireText(project.project.name, field: "migration project name", maximum: 256)
            guard !project.project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceMigrationProjectIntakeError.invalidProject
            }
            guard validRoots[project.rootPath] != nil else { throw WorkspaceMigrationProjectIntakeError.unreferencedProject }
            guard projectByRoot[project.rootPath] == nil else { throw WorkspaceMigrationProjectIntakeError.duplicateRoot }
            guard rootsByID[project.project.id] == nil else { throw WorkspaceMigrationProjectIntakeError.duplicateProjectID }
            projectByRoot[project.rootPath] = project
            rootsByID[project.project.id] = project.rootPath
        }

        var bindings: [LegacyReferenceKey: ArtifactID] = [:]
        for (root, items) in validRoots {
            guard let project = projectByRoot[root] else { continue }
            for item in items where item.legacy.domain == .configuration {
                guard bindings[item.legacy] == nil else { throw WorkspaceMigrationProjectIntakeError.invalidProject }
                bindings[item.legacy] = project.project.id
            }
        }
        let requirements = validRoots.map { root, items in
            Requirement(id: "root:" + root, rootPath: root, canMap: true, items: items.sorted(by: itemOrder))
        } + invalid
        return .init(
            requirements: requirements.sorted { $0.id < $1.id },
            projects: projectByRoot.values.sorted { $0.rootPath < $1.rootPath },
            configurationProjects: bindings
        )
    }
}

private extension WorkspaceMigrationProjectIntake {
    static func requirementID(_ key: LegacyReferenceKey) -> String {
        func field(_ value: String?) -> String {
            guard let value else { return "n" }
            return "s" + String(value.utf8.count) + ":" + value
        }
        return "unmapped|" + field(key.domain.rawValue) + "|" + field(key.ownerPolicyID) + "|" + field(key.identifier)
    }
    static func keyOrder(_ lhs: LegacyReferenceKey, _ rhs: LegacyReferenceKey) -> Bool {
        if lhs.domain != rhs.domain { return lhs.domain.rawValue < rhs.domain.rawValue }
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return (lhs.ownerPolicyID ?? "") < (rhs.ownerPolicyID ?? "")
    }
    static func itemOrder(_ lhs: Item, _ rhs: Item) -> Bool { keyOrder(lhs.legacy, rhs.legacy) }
}
