import Foundation

/// A captured legacy inventory row kept for device-local display and migration
/// continuity. These values are historical metadata only. They must never be
/// used to choose portable authority, native routes, assignments, or updates.
public enum DeviceInventoryPayload: Codable, Hashable, Sendable {
    case skill(Skill)
    case mcpServer(MCPServer)
    case plugin(Plugin)

    fileprivate var legacy: LegacyReferenceKey {
        switch self {
        case .skill(let value): .init(domain: .skill, identifier: value.id)
        case .mcpServer(let value): .init(domain: .mcpServer, identifier: value.id)
        case .plugin(let value): .init(domain: .plugin, identifier: value.id)
        }
    }

    fileprivate func accepts(_ kind: ArtifactKind) -> Bool {
        switch self {
        case .skill: kind == .skill
        case .mcpServer: kind == .mcpServer
        case .plugin: kind == .package || kind == .nativePlugin
        }
    }

    fileprivate func canonicalized() -> Self {
        switch self {
        case .skill(var value):
            if var binding = value.repositoryBinding {
                binding.lastCheckedAt = binding.lastCheckedAt.map(WorkspaceDomainValidation.canonicalDate)
                value.repositoryBinding = binding
            }
            return .skill(value)
        case .mcpServer, .plugin:
            return self
        }
    }
}

public struct DeviceInventoryRecord: Codable, Hashable, Sendable {
    public var artifactID: ArtifactID
    public var legacy: LegacyReferenceKey
    public var captured: DeviceInventoryPayload

    public init(artifactID: ArtifactID, legacy: LegacyReferenceKey, captured: DeviceInventoryPayload) {
        self.artifactID = artifactID
        self.legacy = legacy
        self.captured = captured
    }
}

/// Non-authoritative device metadata for the legacy inventory rows associated
/// with live workspace artifacts. This type intentionally offers no method to
/// reconstruct desired ownership or deployment state from captured rows.
public struct DeviceInventoryState: Codable, Hashable, Sendable {
    public var records: [DeviceInventoryRecord]

    public init(records: [DeviceInventoryRecord] = []) {
        self.records = records
    }

    public init(
        snapshot: WorkspaceSnapshot,
        artifactBindings: [LegacyReferenceKey: ArtifactID]
    ) throws {
        let payloads: [DeviceInventoryPayload] =
            snapshot.skills.map(DeviceInventoryPayload.skill)
            + snapshot.mcpServers.map(DeviceInventoryPayload.mcpServer)
            + snapshot.plugins.map(DeviceInventoryPayload.plugin)
        let legacyKeys = payloads.map(\.legacy)
        guard Set(legacyKeys).count == legacyKeys.count else {
            throw WorkspaceDomainValidationError.duplicate("device inventory legacy identities")
        }
        guard Set(legacyKeys).isSubset(of: Set(artifactBindings.keys)) else {
            throw WorkspaceDomainValidationError.missingReference("device inventory artifact binding")
        }
        let mapped = try payloads.map { payload -> DeviceInventoryRecord in
            let legacy = payload.legacy
            guard let artifactID = artifactBindings[legacy] else {
                throw WorkspaceDomainValidationError.missingReference("device inventory artifact binding")
            }
            return .init(artifactID: artifactID, legacy: legacy, captured: payload)
        }
        self.init(records: mapped)
        try validate()
    }

    public func validate(against portable: PortableWorkspaceDocument? = nil) throws {
        guard Set(records.map(\.legacy)).count == records.count else {
            throw WorkspaceDomainValidationError.duplicate("device inventory legacy identities")
        }
        guard Set(records.map(\.artifactID)).count == records.count else {
            throw WorkspaceDomainValidationError.duplicate("device inventory artifact identities")
        }
        for record in records {
            guard record.legacy.ownerPolicyID == nil, record.legacy == record.captured.legacy else {
                throw WorkspaceDomainValidationError.invalidField("device inventory legacy identity")
            }
            if case .skill(let skill) = record.captured, let binding = skill.repositoryBinding {
                if let date = binding.lastCheckedAt, !date.timeIntervalSinceReferenceDate.isFinite {
                    throw WorkspaceDomainValidationError.invalidField("device inventory source check timestamp")
                }
                if let detail = binding.lastCheckError,
                   SensitiveValueRedactor.containsCredentialValue(in: detail) {
                    throw WorkspaceDomainValidationError.invalidField("device inventory source check detail")
                }
            }
        }
        try validateCapturedRows()

        guard let portable else { return }
        let artifacts = Dictionary(grouping: portable.artifacts, by: \.identity.id)
        let mappings = Dictionary(grouping: portable.configurationState?.identityMap ?? [], by: \.legacy)
        for record in records {
            guard let artifactMatches = artifacts[record.artifactID], artifactMatches.count == 1,
                  let artifact = artifactMatches.first else {
                throw WorkspaceDomainValidationError.missingReference("device inventory artifact")
            }
            guard record.captured.accepts(artifact.identity.kind) else {
                throw WorkspaceDomainValidationError.invalidField("device inventory artifact kind")
            }
            guard let mappingMatches = mappings[record.legacy], mappingMatches.count == 1,
                  mappingMatches[0].objectID.rawValue == record.artifactID.rawValue else {
                throw WorkspaceDomainValidationError.missingReference("device inventory live legacy mapping")
            }
        }
    }

    public func canonicalized() -> Self {
        var value = self
        value.records = value.records.map { record in
            var record = record
            record.captured = record.captured.canonicalized()
            return record
        }.sorted(by: Self.order)
        return value
    }

    private func validateCapturedRows() throws {
        var snapshot = WorkspaceSnapshot(activeProfileID: "")
        for record in records {
            switch record.captured {
            case .skill(let value): snapshot.skills.append(value)
            case .mcpServer(let value): snapshot.mcpServers.append(value)
            case .plugin(let value): snapshot.plugins.append(value)
            }
        }
        try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
    }

    private static func order(_ lhs: DeviceInventoryRecord, _ rhs: DeviceInventoryRecord) -> Bool {
        let left = (lhs.legacy.domain.rawValue, lhs.legacy.identifier, lhs.artifactID.rawValue.uuidString)
        let right = (rhs.legacy.domain.rawValue, rhs.legacy.identifier, rhs.artifactID.rawValue.uuidString)
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }
}
