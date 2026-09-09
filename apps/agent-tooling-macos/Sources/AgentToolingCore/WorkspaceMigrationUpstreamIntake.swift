import CryptoKit
import Foundation

/// Selects one previously recorded upstream installation using only checkpoint
/// evidence. It does not open, inspect, or otherwise trust the selected path.
public struct WorkspaceMigrationUpstreamIntake: Sendable {
    public struct Candidate: Sendable, Equatable, Hashable {
        public let id: String
        public let directoryPath: String
        public let directoryFingerprint: String
        public init(id: String, directoryPath: String, directoryFingerprint: String) {
            self.id = id; self.directoryPath = directoryPath; self.directoryFingerprint = directoryFingerprint
        }
    }
    public struct Requirement: Sendable, Equatable, Hashable {
        public let id: String
        public let legacy: LegacyReferenceKey
        public let displayName: String
        public let repositoryURL: String?
        public let requestedRef: String?
        public let packageRelativePath: String?
        public let installedRevision: SourceRevision?
        public let candidates: [Candidate]
    }

    public let intake: WorkspaceMigrationIntake
    public let requirements: [Requirement]
    public let selections: [LegacyReferenceKey: String]

    public static func review(
        intake: WorkspaceMigrationIntake,
        workspaceID: WorkspaceObjectID,
        selections requested: [LegacyReferenceKey: String] = [:],
        requiringReview: Set<LegacyReferenceKey> = []
    ) throws -> Self {
        var nativeChildren = Set(intake.choices.flatMap { choice -> [LegacyReferenceKey] in
            guard case let .nativePackage(_, children) = choice.strategy else { return [] }
            return children.map(\.legacy)
        })
        for plugin in intake.snapshot.plugins {
            nativeChildren.formUnion(plugin.skills.map { .init(domain: .skill, identifier: $0) })
        }
        for observation in intake.snapshot.targetObservations {
            for (skillID, metadata) in observation.skillMetadata where metadata.providerPluginID != nil {
                nativeChildren.insert(.init(domain: .skill, identifier: skillID))
            }
            for metadata in observation.pluginMetadata.values {
                nativeChildren.formUnion(metadata.skillIDs.map { .init(domain: .skill, identifier: $0) })
            }
        }
        let upstreamIssues = Set(intake.issues.filter { $0.reason == .upstreamInstallation }.map(\.legacy))
        let skills = Dictionary(grouping: intake.snapshot.skills) { LegacyReferenceKey(domain: .skill, identifier: $0.id) }
        var needed = upstreamIssues
        for key in requiringReview where !nativeChildren.contains(key) {
            guard let values = skills[key], values.count == 1 else { continue }
            needed.insert(key)
        }

        var requirements: [Requirement] = []
        var accepted: [LegacyReferenceKey: String] = [:]
        var selectedChoices: [WorkspaceMigrationInventoryChoice] = []
        var selectedKeys = Set<LegacyReferenceKey>()
        for key in needed.sorted(by: keyOrder) {
            guard let values = skills[key], values.count == 1, let skill = values.first,
                  !nativeChildren.contains(key) else { continue }
            guard let binding = skill.repositoryBinding else {
                requirements.append(missingRequirement(for: key, skill: skill))
                continue
            }
            let requirement = requirement(for: key, skill: skill, binding: binding)
            requirements.append(requirement)
            guard let selection = requested[key], requirement.candidates.contains(where: { $0.id == selection }) else { continue }
            guard let candidate = requirement.candidates.first(where: { $0.id == selection }) else { continue }
            let sourceID = try WorkspaceMigrationIntake.stableID(workspaceID: workspaceID, skillID: skill.id, role: "source")
            let subscriptionID = try WorkspaceMigrationIntake.stableID(workspaceID: workspaceID, skillID: skill.id, role: "subscription")
            selectedChoices.append(.init(legacy: key, strategy: .centralUpstream(
                installedDirectory: URL(fileURLWithPath: candidate.directoryPath), sourceID: sourceID, subscriptionID: subscriptionID
            )))
            accepted[key] = selection
            selectedKeys.insert(key)
        }

        let choices = intake.choices.filter { choice in
            guard needed.contains(choice.legacy) else { return true }
            if requiringReview.contains(choice.legacy) { return false }
            if case .centralUpstream = choice.strategy { return false }
            return true
        } + selectedChoices
        var issues = intake.issues.filter { issue in
            !(needed.contains(issue.legacy) && issue.reason == .upstreamInstallation && selectedKeys.contains(issue.legacy))
        }
        for requirement in requirements where !selectedKeys.contains(requirement.legacy) {
            if !issues.contains(where: { $0.legacy == requirement.legacy && $0.reason == .upstreamInstallation }) {
                issues.append(.init(legacy: requirement.legacy, displayName: requirement.displayName, reason: .upstreamInstallation))
            }
        }
        return .init(
            intake: .init(choices: choices, issues: issues.sorted { $0.displayName < $1.displayName }, snapshot: intake.snapshot),
            requirements: requirements.sorted { keyOrder($0.legacy, $1.legacy) }, selections: accepted
        )
    }
}

private extension WorkspaceMigrationUpstreamIntake {
    static func missingRequirement(for key: LegacyReferenceKey, skill: Skill) -> Requirement {
        .init(id: requirementID(key), legacy: key, displayName: skill.displayName,
              repositoryURL: nil, requestedRef: nil, packageRelativePath: nil,
              installedRevision: nil, candidates: [])
    }

    static func requirement(for key: LegacyReferenceKey, skill: Skill, binding: SkillRepositoryBinding) -> Requirement {
        let revision: SourceRevision?
        if let value = binding.installedRevision {
            revision = value.count == 40 ? .init(kind: .gitCommitSHA1, value: value)
                : value.count == 64 ? .init(kind: .gitCommitSHA256, value: value) : nil
        } else { revision = nil }
        let valid = (try? binding.validate()) != nil && revision != nil
        let candidates = valid ? binding.installedFingerprints.compactMap { path, fingerprint -> Candidate? in
            guard let revision else { return nil }
            return .init(id: candidateID(binding: binding, revision: revision, path: path, fingerprint: fingerprint),
                         directoryPath: path, directoryFingerprint: fingerprint)
        }.sorted { $0.directoryPath < $1.directoryPath } : []
        return .init(id: requirementID(key), legacy: key, displayName: skill.displayName,
                     repositoryURL: valid ? binding.repositoryURL : nil, requestedRef: valid ? binding.ref : nil,
                     packageRelativePath: valid ? binding.subdirectory : nil, installedRevision: valid ? revision : nil,
                     candidates: candidates)
    }

    static func candidateID(binding: SkillRepositoryBinding, revision: SourceRevision, path: String, fingerprint: String) -> String {
        var bytes = Data("agent-tooling.upstream-intake-candidate.v1\\0".utf8)
        for value in [binding.repositoryURL, binding.ref, binding.subdirectory, revision.kind.rawValue, revision.value, path, fingerprint] {
            let field = Data(value.precomposedStringWithCanonicalMapping.utf8)
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(field)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func requirementID(_ key: LegacyReferenceKey) -> String {
        "upstream|" + key.domain.rawValue + "|" + String(key.identifier.utf8.count) + ":" + key.identifier
    }
    static func keyOrder(_ lhs: LegacyReferenceKey, _ rhs: LegacyReferenceKey) -> Bool {
        if lhs.domain != rhs.domain { return lhs.domain.rawValue < rhs.domain.rawValue }
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return (lhs.ownerPolicyID ?? "") < (rhs.ownerPolicyID ?? "")
    }
}
