import Foundation

public struct WorkspaceRevision: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var parentIDs: [WorkspaceObjectID]
    public var documentDigest: DocumentDigest
    public var writerID: WorkspaceObjectID
    public var createdAt: Date

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(),
        parentIDs: [WorkspaceObjectID] = [],
        documentDigest: DocumentDigest = .unsealed,
        writerID: WorkspaceObjectID,
        createdAt: Date = .now
    ) {
        self.id = id
        self.parentIDs = parentIDs
        self.documentDigest = documentDigest
        self.writerID = writerID
        self.createdAt = createdAt
    }
}

public struct PortableWorkspaceDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt = 5

    public var schemaVersion: UInt
    public var minimumReaderVersion: UInt
    public var minimumWriterVersion: UInt
    public var workspaceID: WorkspaceObjectID
    public var revision: WorkspaceRevision
    public var artifacts: [ArtifactRecord]
    public var sources: [PortableSourceDescriptor]
    public var subscriptions: [UpstreamSubscription]
    public var logicalProjects: [LogicalProjectRecord]
    public var assignments: [AssignmentContribution]
    public var presets: [PresetRecord]
    public var tombstones: [ArtifactTombstone]
    /// Nil only for the original v1 wire format.
    public var configurationState: WorkspaceConfigurationState?
    /// Absent from schema 1/2; an explicit array in schema 3.
    public var mcpDefinitions: [PortableMCPDefinitionRecord]?

    public init(
        schemaVersion: UInt = Self.currentSchemaVersion,
        minimumReaderVersion: UInt = Self.currentSchemaVersion,
        minimumWriterVersion: UInt = Self.currentSchemaVersion,
        workspaceID: WorkspaceObjectID = WorkspaceObjectID(),
        revision: WorkspaceRevision,
        artifacts: [ArtifactRecord] = [],
        sources: [PortableSourceDescriptor] = [],
        subscriptions: [UpstreamSubscription] = [],
        logicalProjects: [LogicalProjectRecord] = [],
        assignments: [AssignmentContribution] = [],
        presets: [PresetRecord] = [],
        tombstones: [ArtifactTombstone] = [],
        configurationState: WorkspaceConfigurationState? = .init(),
        mcpDefinitions: [PortableMCPDefinitionRecord]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.minimumReaderVersion = minimumReaderVersion
        self.minimumWriterVersion = minimumWriterVersion
        self.workspaceID = workspaceID
        self.revision = revision
        self.artifacts = artifacts
        self.sources = sources
        self.subscriptions = subscriptions
        self.logicalProjects = logicalProjects
        self.assignments = assignments
        self.presets = presets
        self.tombstones = tombstones
        self.configurationState = configurationState
        self.mcpDefinitions = mcpDefinitions ?? (schemaVersion >= 3 ? [] : nil)
    }

    public func validateStructure() throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion),
            minimumReaderVersion <= Self.currentSchemaVersion,
            minimumWriterVersion <= Self.currentSchemaVersion,
            minimumReaderVersion > 0,
            minimumWriterVersion > 0
        else { throw WorkspaceDomainValidationError.unsupportedVersion(schemaVersion) }

        guard minimumReaderVersion == schemaVersion, minimumWriterVersion == schemaVersion,
            ((schemaVersion == 1 && configurationState == nil && mcpDefinitions == nil)
            || (schemaVersion == 2 && configurationState != nil && mcpDefinitions == nil)
            || (schemaVersion >= 3 && configurationState != nil && mcpDefinitions != nil))
        else { throw WorkspaceDomainValidationError.invalidField("workspace schema feature version") }

        try WorkspaceDomainValidation.requireDigest(revision.documentDigest.value, field: "revision.documentDigest")
        try requireUnique(revision.parentIDs, field: "revision.parentIDs")
        guard !revision.parentIDs.contains(revision.id) else {
            throw WorkspaceDomainValidationError.invalidField("revision.parentIDs")
        }

        try requireUnique(artifacts.map(\.identity.id), field: "artifact IDs")
        try requireUnique(sources.map(\.id), field: "source IDs")
        try requireUnique(subscriptions.map(\.id), field: "subscription IDs")
        try requireUnique(logicalProjects.map(\.id), field: "logical project IDs")
        try requireUnique(assignments.map(\.id), field: "assignment IDs")
        try requireUnique(presets.map(\.id), field: "preset IDs")
        try requireUnique(tombstones.map(\.artifactID), field: "tombstone IDs")

        let artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.identity.id, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let subscriptionsByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
        let projectsByID = Dictionary(uniqueKeysWithValues: logicalProjects.map { ($0.id, $0) })
        let presetsByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        let liveIDs = Set(artifactsByID.keys)
        guard liveIDs.isDisjoint(with: tombstones.map(\.artifactID)) else {
            throw WorkspaceDomainValidationError.duplicate("live and tombstoned artifact ID")
        }

        var aliases: [ExternalAlias: ArtifactID] = [:]
        for artifact in artifacts {
            try validate(artifact, artifactsByID: artifactsByID)
            for alias in artifact.identity.aliases {
                try validate(alias)
                if let existing = aliases[alias], existing != artifact.identity.id {
                    throw WorkspaceDomainValidationError.duplicate("artifact alias \(alias.namespace):\(alias.value)")
                }
                aliases[alias] = artifact.identity.id
            }
        }
        for tombstone in tombstones {
            try requireUnique(tombstone.aliases, field: "tombstone aliases")
            for alias in tombstone.aliases {
                try validate(alias)
                if let existing = aliases[alias], existing != tombstone.artifactID {
                    throw WorkspaceDomainValidationError.duplicate("tombstone alias \(alias.namespace):\(alias.value)")
                }
                aliases[alias] = tombstone.artifactID
            }
        }
        try validateParentGraph(artifactsByID)
        try validateNativeRouteUniqueness(artifacts)
        if let mcpDefinitions {
            try WorkspaceMCPDefinitionValidation.validatePortable(mcpDefinitions, artifacts: artifacts)
        }

        for source in sources {
            try requireUnique(source.packageRelativePaths, field: "source package paths")
            for path in source.packageRelativePaths {
                try WorkspaceDomainValidation.requirePortablePath(path, field: "source.packageRelativePaths", allowRootDot: true)
            }
            if let url = source.repositoryURL {
                try WorkspaceDomainValidation.requireCredentialFreeHTTPS(url, field: "source.repositoryURL")
            }
            if let requestedRef = source.requestedRef {
                try WorkspaceDomainValidation.requireText(requestedRef, field: "source.requestedRef", maximum: 256)
            }
            if source.role == .publisherRepository, source.repositoryURL == nil || source.requestedRef == nil {
                throw WorkspaceDomainValidationError.invalidField("publisher source locator")
            }
        }

        for subscription in subscriptions {
            guard let owningArtifact = artifactsByID[subscription.artifactID],
                owningArtifact.identity.parentPackageID == nil,
                owningArtifact.identity.kind == .package || owningArtifact.identity.kind == .skill,
                owningArtifact.authority == .centralUpstream(subscriptionID: subscription.id)
            else { throw WorkspaceDomainValidationError.missingReference("subscription owning artifact") }
            guard let source = sourcesByID[subscription.sourceID], source.role == .publisherRepository,
                subscription.lock.sourceRootID == subscription.sourceID,
                source.packageRelativePaths.contains(subscription.lock.packageRelativePath)
            else { throw WorkspaceDomainValidationError.missingReference("subscription.sourceID") }
            try validate(subscription.lock)
            if let materializedDigest = owningArtifact.contentDigest,
                materializedDigest != subscription.lock.approvedContent
            {
                throw WorkspaceDomainValidationError.invalidField("upstream materialized content digest")
            }
        }

        for artifact in artifacts {
            switch artifact.authority {
            case .centralUpstream(let subscriptionID):
                guard let subscription = subscriptionsByID[subscriptionID],
                    isDescendantOrSelf(artifact.identity.id, of: subscription.artifactID, artifactsByID: artifactsByID)
                else { throw WorkspaceDomainValidationError.missingReference("artifact upstream subscription") }
            case .attachedAuthoring(let sourceID):
                guard sourcesByID[sourceID]?.role == .attachedAuthoring else {
                    throw WorkspaceDomainValidationError.missingReference("artifact attached source")
                }
            case .nativeOwned: break
            case .centralPersonal, .trackedOnly: break
            }
        }

        for project in logicalProjects {
            try WorkspaceDomainValidation.requireText(project.name, field: "logical project name", maximum: 256)
            try requireUnique(project.repositoryHints, field: "logical project repository hints")
            for hint in project.repositoryHints {
                try WorkspaceDomainValidation.requireCredentialFreeHTTPS(hint, field: "logical project repository hint")
            }
            guard artifactsByID[project.id]?.identity.kind == .logicalProject else {
                throw WorkspaceDomainValidationError.missingReference("logical project artifact")
            }
        }

        for preset in presets {
            try WorkspaceDomainValidation.requireText(preset.name, field: "preset name", maximum: 256)
            guard preset.revision > 0, artifactsByID[preset.id]?.identity.kind == .preset else {
                throw WorkspaceDomainValidationError.missingReference("preset artifact")
            }
            try requireUnique(preset.memberArtifactIDs, field: "preset members")
            for member in preset.memberArtifactIDs where artifactsByID[member] == nil {
                throw WorkspaceDomainValidationError.missingReference("preset member")
            }
        }

        for assignment in assignments {
            guard assignment.desiredPresence, let assignedArtifact = artifactsByID[assignment.artifactID] else {
                throw WorkspaceDomainValidationError.missingReference("assignment artifact")
            }
            if assignedArtifact.identity.parentPackageID != nil,
                case .nativeOwned = assignedArtifact.authority
            {
                throw WorkspaceDomainValidationError.invalidField("native plugin child assignment")
            }
            try validate(assignment.destination)
            if let projectID = assignment.destination.logicalProjectID, projectsByID[projectID] == nil {
                throw WorkspaceDomainValidationError.missingReference("assignment logical project")
            }
            if let deviceIDs = assignment.destination.deviceIDs {
                try requireUnique(deviceIDs, field: "assignment destination devices")
            }
            switch assignment.reason {
            case .manual, .onboarding: break
            case .preset(let id) where presetsByID[id] != nil: break
            case .projectDeclaration(let id) where projectsByID[id] != nil: break
            default: throw WorkspaceDomainValidationError.missingReference("assignment reason")
            }
        }
        try validateAssignmentConflicts(assignments)
        try configurationState?.validate(artifacts: artifacts, logicalProjects: logicalProjects)
    }

    func canonicalized() -> Self {
        var value = self
        value.configurationState = value.configurationState?.canonicalized()
        value.mcpDefinitions?.sort { $0.artifactID < $1.artifactID }
        value.revision.createdAt = WorkspaceDomainValidation.canonicalDate(value.revision.createdAt)
        value.revision.parentIDs.sort()
        value.artifacts = value.artifacts.map { artifact in
            var artifact = artifact
            artifact.identity.aliases.sort(by: aliasSort)
            artifact.nativeRoutes.sort {
                $0.client == $1.client
                    ? $0.externalPluginID < $1.externalPluginID
                    : $0.client.rawValue < $1.client.rawValue
            }
            return artifact
        }.sorted { $0.identity.id < $1.identity.id }
        value.sources = value.sources.map { source in
            var source = source
            source.packageRelativePaths.sort()
            return source
        }.sorted { $0.id < $1.id }
        value.subscriptions.sort { $0.id < $1.id }
        value.logicalProjects = value.logicalProjects.map { project in
            var project = project
            project.repositoryHints.sort()
            return project
        }.sorted { $0.id < $1.id }
        value.assignments = value.assignments.map { assignment in
            var assignment = assignment
            assignment.destination.deviceIDs?.sort()
            return assignment
        }.sorted { $0.id < $1.id }
        value.presets = value.presets.map { preset in
            var preset = preset
            preset.memberArtifactIDs.sort()
            return preset
        }.sorted { $0.id < $1.id }
        value.tombstones = value.tombstones.map { tombstone in
            var tombstone = tombstone
            tombstone.aliases.sort(by: aliasSort)
            return tombstone
        }.sorted { $0.artifactID < $1.artifactID }
        return value
    }

    private func validate(_ artifact: ArtifactRecord, artifactsByID: [ArtifactID: ArtifactRecord]) throws {
        try WorkspaceDomainValidation.requireText(artifact.identity.displayName, field: "artifact display name", maximum: 512)
        try requireUnique(artifact.identity.aliases, field: "artifact aliases")
        if let declaredName = artifact.declaredName {
            try WorkspaceDomainValidation.requireText(declaredName, field: "artifact declared name", maximum: 256)
        }
        if let path = artifact.packageRelativePath {
            try WorkspaceDomainValidation.requirePortablePath(path, field: "artifact package path", allowRootDot: true)
        }
        if let parentID = artifact.identity.parentPackageID {
            guard let parent = artifactsByID[parentID], parentID != artifact.identity.id else {
                throw WorkspaceDomainValidationError.missingReference("artifact parent package")
            }
            if artifact.packageRelativePath == nil {
                // A native MCP declaration has no file of its own, and a package
                // recorded without usable client evidence has no located member
                // files at all. Both keep membership without claiming a path.
                let nativeMCPDeclaration = schemaVersion >= 4
                    && artifact.identity.kind == .mcpServer
                    && artifact.authority == .nativeOwned
                    && parent.authority == .nativeOwned
                let recordedPackageMember = schemaVersion >= 5
                    && artifact.authority == .trackedOnly
                    && parent.authority == .trackedOnly
                guard nativeMCPDeclaration || recordedPackageMember,
                      artifact.declaredName != nil,
                      artifact.contentDigest == nil,
                      artifact.nativeRoutes.isEmpty,
                      parent.identity.kind == .nativePlugin else {
                    throw WorkspaceDomainValidationError.missingReference("artifact parent package path")
                }
            }
        }
        if artifact.identity.derivedFrom == artifact.identity.id {
            throw WorkspaceDomainValidationError.invalidField("artifact derivedFrom")
        }
        if let digest = artifact.contentDigest {
            try WorkspaceDomainValidation.requireDigest(digest.value, field: "artifact content digest")
        }
        switch artifact.authority {
        case .nativeOwned where artifact.identity.parentPackageID == nil:
            try requireUnique(artifact.nativeRoutes.map(\.client), field: "native route clients")
            for route in artifact.nativeRoutes {
                try WorkspaceDomainValidation.requireText(
                    route.externalPluginID, field: "native plugin identifier", maximum: 512)
            }
        case .nativeOwned:
            guard artifact.nativeRoutes.isEmpty else {
                throw WorkspaceDomainValidationError.invalidField("native child routes")
            }
        case .centralPersonal, .centralUpstream, .attachedAuthoring, .trackedOnly:
            guard artifact.nativeRoutes.isEmpty else {
                throw WorkspaceDomainValidationError.invalidField("non-native routes")
            }
        }
    }

    private func validate(_ alias: ExternalAlias) throws {
        try WorkspaceDomainValidation.requireText(alias.namespace, field: "alias namespace", maximum: 128)
        try WorkspaceDomainValidation.requireText(alias.value, field: "alias value", maximum: 1_024)
    }

    private func validate(_ lock: UpstreamLock) throws {
        try WorkspaceDomainValidation.requireText(lock.publisherID, field: "upstream publisher", maximum: 512)
        try WorkspaceDomainValidation.requireText(lock.requestedRef, field: "upstream requested ref", maximum: 256)
        try WorkspaceDomainValidation.requireRevision(lock.approvedRevision, field: "upstream approved revision")
        try WorkspaceDomainValidation.requireDigest(lock.approvedContent.value, field: "upstream content digest")
        try WorkspaceDomainValidation.requirePortablePath(lock.packageRelativePath, field: "upstream package path", allowRootDot: true)
    }

    private func validate(_ destination: PortableDestination) throws {
        switch destination.scope {
        case .project, .localProject:
            guard destination.logicalProjectID != nil else {
                throw WorkspaceDomainValidationError.missingReference("project destination logical project")
            }
        case .user, .workspace, .managed, .account, .session:
            guard destination.logicalProjectID == nil else {
                throw WorkspaceDomainValidationError.invalidField("non-project destination logical project")
            }
        }
    }

    /// A native package identifier belongs to at most one live artifact, the
    /// same way an alias does: `(namespace, value)` identifies one item, and a
    /// `(client, externalPluginID)` route is that identity in the client's own
    /// vocabulary. Without this, two records of one package can exist, and a
    /// deployment would ask the client to install it twice.
    private func validateNativeRouteUniqueness(_ artifacts: [ArtifactRecord]) throws {
        var seen: [NativePackageRoute: ArtifactID] = [:]
        for artifact in artifacts {
            for route in artifact.nativeRoutes {
                if let existing = seen[route], existing != artifact.identity.id {
                    throw WorkspaceDomainValidationError.duplicate(
                        "native package route \(route.client.rawValue):\(route.externalPluginID)")
                }
                seen[route] = artifact.identity.id
            }
        }
    }

    private func validateParentGraph(_ artifacts: [ArtifactID: ArtifactRecord]) throws {
        for id in artifacts.keys {
            var visited: Set<ArtifactID> = []
            var cursor: ArtifactID? = id
            while let current = cursor {
                guard visited.insert(current).inserted else {
                    throw WorkspaceDomainValidationError.invalidField("artifact parent cycle")
                }
                cursor = artifacts[current]?.identity.parentPackageID
            }
        }
        for artifact in artifacts.values {
            guard let parentID = artifact.identity.parentPackageID, let parent = artifacts[parentID] else { continue }
            guard parent.identity.kind == .package || parent.identity.kind == .nativePlugin,
                parent.authority == artifact.authority
            else { throw WorkspaceDomainValidationError.invalidField("artifact inherited authority") }
        }
    }

    private func isDescendantOrSelf(
        _ id: ArtifactID, of ancestor: ArtifactID, artifactsByID: [ArtifactID: ArtifactRecord]
    ) -> Bool {
        var cursor: ArtifactID? = id
        var visited: Set<ArtifactID> = []
        while let current = cursor, visited.insert(current).inserted {
            if current == ancestor { return true }
            cursor = artifactsByID[current]?.identity.parentPackageID
        }
        return false
    }

    private func validateAssignmentConflicts(_ assignments: [AssignmentContribution]) throws {
        var enabled: [AssignmentTarget: Bool] = [:]
        for assignment in assignments {
            guard let desiredEnabled = assignment.desiredEnabled else { continue }
            var destination = assignment.destination
            destination.deviceIDs?.sort()
            let key = AssignmentTarget(artifactID: assignment.artifactID, destination: destination)
            if let existing = enabled[key], existing != desiredEnabled {
                throw WorkspaceDomainValidationError.conflictingAssignment(assignment.artifactID.rawValue.uuidString.lowercased())
            }
            enabled[key] = desiredEnabled
        }
    }

    private struct AssignmentTarget: Hashable {
        var artifactID: ArtifactID
        var destination: PortableDestination
    }

    private func requireUnique<T: Hashable>(_ values: [T], field: String) throws {
        guard Set(values).count == values.count else { throw WorkspaceDomainValidationError.duplicate(field) }
    }

    private func aliasSort(_ lhs: ExternalAlias, _ rhs: ExternalAlias) -> Bool {
        lhs.namespace == rhs.namespace ? lhs.value < rhs.value : lhs.namespace < rhs.namespace
    }
}
