import Foundation

/// A validated, immutable index for library presentation. It exposes requested
/// assignment intent without treating that intent as installed, authorized, or
/// currently available state.
public struct WorkspaceLibraryReadModel: Sendable, Equatable {
    public let rows: [WorkspaceLibraryReadModelRow]
    public let presets: [WorkspaceLibraryPresetReadModel]
    public let projects: [WorkspaceLibraryProjectReadModel]

    /// Tools that reach the library inside a plugin rather than on their own,
    /// and so are folded into a row instead of being one.
    public var nestedToolCount: Int { rows.reduce(0) { $0 + $1.childCount } }

    /// Every tool the library holds. `rows.count` is the number of entries a
    /// list can show, which is a smaller number whenever plugins carry skills
    /// or servers of their own; anything reporting a library size to a person
    /// wants this one.
    public var toolCount: Int { rows.count + nestedToolCount }

    private let searchableRows: [ArtifactID: String]
    /// Precomputed so a project view never scans every row's assignments.
    private let rowIDsByProject: [ArtifactID: [ArtifactID]]
    private let globalRowIDs: [ArtifactID]

    public init(snapshot: WorkspaceApplicationSnapshot) throws {
        try snapshot.document.validateStructure()
        try snapshot.device.validateStructure(against: snapshot.document)

        let artifacts = Dictionary(uniqueKeysWithValues: snapshot.document.artifacts.map { ($0.identity.id, $0) })
        let childrenByParent = Dictionary(grouping: snapshot.document.artifacts.compactMap { artifact in
            artifact.identity.parentPackageID.map { ($0, artifact) }
        }, by: \.0).mapValues { $0.map(\.1) }
        let sources = Dictionary(uniqueKeysWithValues: snapshot.document.sources.map { ($0.id, $0) })
        let subscriptions = Dictionary(uniqueKeysWithValues: snapshot.document.subscriptions.map { ($0.id, $0) })
        let assignments = Dictionary(grouping: snapshot.document.assignments, by: \.artifactID)
        let observations = Self.observedDescriptions(snapshot.device.inventoryState)
        let connections = Self.connections(
            definitions: snapshot.document.mcpDefinitions, bindings: snapshot.device.mcpBindings)

        let rootArtifacts = snapshot.document.artifacts.filter {
            $0.identity.parentPackageID == nil && Self.isLibraryArtifact($0.identity.kind)
        }
        let rows = rootArtifacts.map { artifact in
            let children = Self.descendants(of: artifact.identity.id, childrenByParent: childrenByParent)
                .compactMap { child -> WorkspaceLibraryIncludedItem? in
                    guard let parentID = child.identity.parentPackageID else { return nil }
                    return WorkspaceLibraryIncludedItem(
                        artifactID: child.identity.id,
                        displayName: child.identity.displayName,
                        kind: child.identity.kind,
                        ownership: Self.ownership(child.authority),
                        parentPluginLabel: artifacts[parentID]?.identity.displayName,
                        declaredName: child.declaredName,
                        observedDescription: observations[child.identity.id],
                        requestedAssignments: Self.requestedAssignments(
                            assignments[child.identity.id] ?? [], deviceID: snapshot.device.deviceID
                        ),
                        nativeRoutes: Self.routes(child.nativeRoutes),
                        connection: connections[child.identity.id]
                    )
                }
                .sorted(by: Self.order)
            let authority = Self.ownership(artifact.authority)
            return WorkspaceLibraryReadModelRow(
                artifactID: artifact.identity.id,
                displayName: artifact.identity.displayName,
                kind: artifact.identity.kind,
                ownership: authority,
                parentPluginLabel: nil,
                declaredName: artifact.declaredName,
                sourceLabel: Self.sourceLabel(
                    authority: artifact.authority,
                    sources: sources,
                    subscriptions: subscriptions
                ),
                observedDescription: observations[artifact.identity.id],
                includedChildren: children,
                requestedAssignments: Self.requestedAssignments(
                    assignments[artifact.identity.id] ?? [], deviceID: snapshot.device.deviceID
                ),
                isAssignable: authority != .trackedOnly,
                assignmentExplanation: authority == .trackedOnly
                    ? "Tracked in this library. Choose how to manage it before assigning."
                    : nil,
                assignableReasons: authority == .trackedOnly ? [] : [.manual, .preset],
                nativeRoutes: Self.routes(artifact.nativeRoutes),
                connection: connections[artifact.identity.id]
            )
        }.sorted(by: Self.order)
        let presets: [WorkspaceLibraryPresetReadModel] = snapshot.document.presets.map {
            .init(id: $0.id, name: $0.name, revision: $0.revision, memberArtifactIDs: $0.memberArtifactIDs.sorted())
        }.sorted { Self.nameOrder($0.name, $0.id, $1.name, $1.id) }
        let projects: [WorkspaceLibraryProjectReadModel] = snapshot.document.logicalProjects.map {
            .init(id: $0.id, name: $0.name, repositoryHints: $0.repositoryHints.sorted())
        }.sorted { Self.nameOrder($0.name, $0.id, $1.name, $1.id) }
        self.rows = rows
        self.presets = presets
        self.projects = projects
        self.searchableRows = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.artifactID, Self.searchText(for: $0))
        })
        var byProject: [ArtifactID: [ArtifactID]] = [:]
        var global: [ArtifactID] = []
        let known = Set(projects.map(\.id))
        for row in rows {
            var seen = Set<ArtifactID>()
            var isGlobal = false
            for assignment in row.requestedAssignments {
                guard let projectID = assignment.destination.logicalProjectID else { isGlobal = true; continue }
                guard known.contains(projectID), seen.insert(projectID).inserted else { continue }
                byProject[projectID, default: []].append(row.artifactID)
            }
            if isGlobal { global.append(row.artifactID) }
        }
        self.rowIDsByProject = byProject
        self.globalRowIDs = global
    }

    /// Rows with at least one saved assignment for this project, in row order.
    /// Assignments recorded for another device are included: they are shared
    /// intent, and this Mac's installation is reported separately.
    public func rows(inProject projectID: ArtifactID) -> [WorkspaceLibraryReadModelRow] {
        let ids = Set(rowIDsByProject[projectID] ?? [])
        return rows.filter { ids.contains($0.artifactID) }
    }

    /// Rows assigned without a project, which every project also inherits from
    /// the apps themselves. Presence in a client is verified separately.
    public var globallyAssignedRows: [WorkspaceLibraryReadModelRow] {
        let ids = Set(globalRowIDs)
        return rows.filter { ids.contains($0.artifactID) }
    }

    public func assignedItemCount(inProject projectID: ArtifactID) -> Int {
        rowIDsByProject[projectID]?.count ?? 0
    }

    public func filteredRows(matching query: String) -> [WorkspaceLibraryReadModelRow] {
        let query = Self.normalized(query)
        guard !query.isEmpty else { return rows }
        return rows.filter { searchableRows[$0.artifactID, default: ""].contains(query) }
    }

    private static func descendants(
        of rootID: ArtifactID,
        childrenByParent: [ArtifactID: [ArtifactRecord]]
    ) -> [ArtifactRecord] {
        var queue = childrenByParent[rootID] ?? []
        var result: [ArtifactRecord] = []
        var visited = Set<ArtifactID>()
        var index = 0
        while index < queue.count {
            let child = queue[index]
            index += 1
            guard visited.insert(child.identity.id).inserted else { continue }
            result.append(child)
            queue += childrenByParent[child.identity.id] ?? []
        }
        return result
    }

    private static func isLibraryArtifact(_ kind: ArtifactKind) -> Bool {
        [.package, .skill, .mcpServer, .nativePlugin].contains(kind)
    }

    private static func ownership(_ authority: ContentAuthority) -> WorkspaceLibraryOwnership {
        switch authority {
        case .centralPersonal: .centralPersonal
        case .centralUpstream: .centralUpstream
        case .nativeOwned: .nativeOwned
        case .attachedAuthoring: .attachedAuthoring
        case .trackedOnly: .trackedOnly
        }
    }

    private static func sourceLabel(
        authority: ContentAuthority,
        sources: [WorkspaceObjectID: PortableSourceDescriptor],
        subscriptions: [WorkspaceObjectID: UpstreamSubscription]
    ) -> String? {
        let sourceID: WorkspaceObjectID?
        switch authority {
        case .centralUpstream(let subscriptionID): sourceID = subscriptions[subscriptionID]?.sourceID
        case .attachedAuthoring(let id): sourceID = id
        default: sourceID = nil
        }
        guard let sourceID, let source = sources[sourceID] else { return nil }
        guard let url = source.repositoryURL, let components = URLComponents(string: url), let host = components.host else {
            return source.role == .attachedAuthoring ? "Attached authoring source" : nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    private static func requestedAssignments(
        _ contributions: [AssignmentContribution], deviceID: WorkspaceObjectID
    ) -> [WorkspaceLibraryRequestedAssignment] {
        contributions.map {
            let scope: WorkspaceLibraryDeviceScope
            switch $0.destination.deviceIDs {
            case nil: scope = .allEnrolledDevices
            case []: scope = .noDevices
            case let ids?:
                let containsCurrent = ids.contains(deviceID)
                scope = containsCurrent
                    ? (ids.count == 1 ? .thisDevice : .thisAndOtherDevices)
                    : .otherDevices
            }
            return .init(
                id: $0.id,
                destination: $0.destination,
                reason: $0.reason,
                desiredPresence: $0.desiredPresence,
                desiredEnabled: $0.desiredEnabled,
                deviceScope: scope
            )
        }.sorted { $0.id < $1.id }
    }

    private static func routes(_ routes: [NativePackageRoute]) -> [WorkspaceLibraryNativeRoute] {
        routes.map { .init(client: $0.client, externalPluginID: $0.externalPluginID) }
            .sorted { $0.client == $1.client ? $0.externalPluginID < $1.externalPluginID : $0.client.rawValue < $1.client.rawValue }
    }

    /// How a recorded connection is reached, joined from the two halves that
    /// hold it: the portable definition every Mac shares and this Mac's own
    /// binding. A connection with no definition gets no entry, which is what a
    /// server this workspace merely observed should look like.
    ///
    /// Nothing secret can arrive here. A portable definition may hold only a
    /// credential-free HTTPS address, and a device binding may hold only an
    /// address or an argument vector that has already been refused if it
    /// carries anything credential-shaped, plus the *names* of the credentials
    /// the server needs. Both are validated before the workspace accepts them.
    private static func connections(
        definitions: [PortableMCPDefinitionRecord]?, bindings: [DeviceMCPDefinitionBinding]?
    ) -> [ArtifactID: WorkspaceLibraryMCPConnection] {
        guard let definitions, !definitions.isEmpty else { return [:] }
        let bindingsByID = Dictionary(
            (bindings ?? []).map { ($0.artifactID, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [ArtifactID: WorkspaceLibraryMCPConnection] = [:]
        for definition in definitions {
            let binding = bindingsByID[definition.artifactID]
            let portableEndpoint: String?
            switch definition.connection {
            case .remoteHTTPS(let url): portableEndpoint = url
            case .deviceBound: portableEndpoint = nil
            }
            let deviceEndpoint: String?
            switch binding?.destination {
            case .httpURL(let url): deviceEndpoint = url
            case .stdio(let executable, let arguments):
                deviceEndpoint = PastedDefinitionParser.shellQuoted([executable] + arguments)
            case nil: deviceEndpoint = nil
            }
            result[definition.artifactID] = .init(
                portableEndpoint: portableEndpoint,
                deviceEndpoint: deviceEndpoint,
                transport: definition.connection.transport,
                authenticationRequirement: binding?.authenticationRequirement ?? .none,
                credentialRequirementNames: (binding?.credentialRequirementNames ?? []).sorted(),
                workspaceRootPath: binding?.workspaceRootPath)
        }
        return result
    }

    private static func observedDescriptions(_ inventory: DeviceInventoryState?) -> [ArtifactID: String] {
        guard let inventory else { return [:] }
        return Dictionary(uniqueKeysWithValues: inventory.records.map { record in
            let description: String
            switch record.captured {
            case .skill(let skill): description = skill.summary
            case .mcpServer(let server): description = server.summary
            case .plugin(let plugin): description = plugin.summary
            }
            return (record.artifactID, description)
        })
    }

    private static func searchText(for row: WorkspaceLibraryReadModelRow) -> String {
        let values = [
            row.displayName, row.kind.rawValue, row.ownership.rawValue, row.parentPluginLabel ?? "", row.sourceLabel ?? "",
            row.observedDescription ?? ""
        ]
        + row.nativeRoutes.map(\.externalPluginID)
        + row.includedChildren.map {
            $0.displayName + " " + $0.kind.rawValue + " " + $0.nativeRoutes.map(\.externalPluginID).joined(separator: " ")
        }
        return normalized(values.joined(separator: " "))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func nameOrder(_ leftName: String, _ leftID: ArtifactID, _ rightName: String, _ rightID: ArtifactID) -> Bool {
        let left = normalized(leftName)
        let right = normalized(rightName)
        return left == right ? leftID < rightID : left < right
    }

    private static func order(_ lhs: WorkspaceLibraryReadModelRow, _ rhs: WorkspaceLibraryReadModelRow) -> Bool {
        nameOrder(lhs.displayName, lhs.artifactID, rhs.displayName, rhs.artifactID)
    }

    private static func order(_ lhs: WorkspaceLibraryIncludedItem, _ rhs: WorkspaceLibraryIncludedItem) -> Bool {
        nameOrder(lhs.displayName, lhs.artifactID, rhs.displayName, rhs.artifactID)
    }
}

public enum WorkspaceLibraryOwnership: String, Sendable, Equatable {
    case centralPersonal, centralUpstream, nativeOwned, attachedAuthoring, trackedOnly
}

public enum WorkspaceLibraryAssignableReason: String, Sendable, Equatable {
    case manual, preset
}

public enum WorkspaceLibraryDeviceScope: String, Sendable, Equatable {
    case allEnrolledDevices, noDevices, thisDevice, thisAndOtherDevices, otherDevices
}

public struct WorkspaceLibraryNativeRoute: Sendable, Equatable {
    public let client: ClientKind
    /// A native adapter identifier, not a verified marketplace publisher claim.
    public let externalPluginID: String

    public init(client: ClientKind, externalPluginID: String) {
        self.client = client
        self.externalPluginID = externalPluginID
    }
}

public struct WorkspaceLibraryRequestedAssignment: Sendable, Equatable, Identifiable {
    public let id: WorkspaceObjectID
    public let destination: PortableDestination
    public let reason: AssignmentReason
    public let desiredPresence: Bool
    public let desiredEnabled: Bool?
    public let deviceScope: WorkspaceLibraryDeviceScope
}

/// How one recorded MCP connection is reached, as far as this workspace can
/// honestly say. It is a declaration, never a claim that the server is running,
/// reachable, or authenticated.
public struct WorkspaceLibraryMCPConnection: Sendable, Equatable {
    /// The reviewed address every Mac shares, or nil when this connection is
    /// resolved separately on each device.
    public let portableEndpoint: String?
    /// This Mac's own address or command line, when one is recorded here. Nil
    /// means this device has no local setup for the connection yet.
    public let deviceEndpoint: String?
    public let transport: MCPTransport
    /// What setting this up requires. It never asserts that an account is
    /// signed in or that a credential is available.
    public let authenticationRequirement: MCPAuthenticationRequirement
    /// Credential names only. Values never enter the workspace.
    public let credentialRequirementNames: [String]
    /// This Mac's workspace root for a workspace-scoped connection.
    public let workspaceRootPath: String?

    public init(
        portableEndpoint: String?,
        deviceEndpoint: String?,
        transport: MCPTransport,
        authenticationRequirement: MCPAuthenticationRequirement,
        credentialRequirementNames: [String],
        workspaceRootPath: String?
    ) {
        self.portableEndpoint = portableEndpoint
        self.deviceEndpoint = deviceEndpoint
        self.transport = transport
        self.authenticationRequirement = authenticationRequirement
        self.credentialRequirementNames = credentialRequirementNames
        self.workspaceRootPath = workspaceRootPath
    }

    /// The address to show and to test against: the shared one when there is
    /// one, this Mac's otherwise. Empty when a device-resolved connection has
    /// no local setup here, which is an answer rather than a missing value.
    public var endpoint: String { portableEndpoint ?? deviceEndpoint ?? "" }
}

public struct WorkspaceLibraryIncludedItem: Sendable, Equatable, Identifiable {
    public let artifactID: ArtifactID
    public var id: ArtifactID { artifactID }
    public let displayName: String
    public let kind: ArtifactKind
    public let ownership: WorkspaceLibraryOwnership
    public let parentPluginLabel: String?
    /// The name recorded when this artifact was declared. This is the only key
    /// that joins a row to a device observation: `nil` means nothing declared
    /// one, so nothing observed on this Mac can be matched to it either.
    public let declaredName: String?
    /// Device-captured legacy description only; nil means no observation exists.
    public let observedDescription: String?
    public let requestedAssignments: [WorkspaceLibraryRequestedAssignment]
    public let nativeRoutes: [WorkspaceLibraryNativeRoute]
    /// Present only for a connection this workspace holds a definition for.
    public let connection: WorkspaceLibraryMCPConnection?

    public init(
        artifactID: ArtifactID,
        displayName: String,
        kind: ArtifactKind,
        ownership: WorkspaceLibraryOwnership,
        parentPluginLabel: String?,
        declaredName: String?,
        observedDescription: String?,
        requestedAssignments: [WorkspaceLibraryRequestedAssignment],
        nativeRoutes: [WorkspaceLibraryNativeRoute],
        connection: WorkspaceLibraryMCPConnection? = nil
    ) {
        self.artifactID = artifactID
        self.displayName = displayName
        self.kind = kind
        self.ownership = ownership
        self.parentPluginLabel = parentPluginLabel
        self.declaredName = declaredName
        self.observedDescription = observedDescription
        self.requestedAssignments = requestedAssignments
        self.nativeRoutes = nativeRoutes
        self.connection = connection
    }
}

public struct WorkspaceLibraryReadModelRow: Sendable, Equatable, Identifiable {
    public let artifactID: ArtifactID
    public var id: ArtifactID { artifactID }
    public let displayName: String
    public let kind: ArtifactKind
    public let ownership: WorkspaceLibraryOwnership
    public let parentPluginLabel: String?
    /// The name recorded when this artifact was declared. This is the only key
    /// that joins a row to a device observation: `nil` means nothing declared
    /// one, so nothing observed on this Mac can be matched to it either.
    public let declaredName: String?
    public let sourceLabel: String?
    /// Device-captured legacy description only; nil means no observation exists.
    public let observedDescription: String?
    public let includedChildren: [WorkspaceLibraryIncludedItem]
    public var childCount: Int { includedChildren.count }
    public let requestedAssignments: [WorkspaceLibraryRequestedAssignment]
    public let isAssignable: Bool
    public let assignmentExplanation: String?
    public let assignableReasons: [WorkspaceLibraryAssignableReason]
    public let nativeRoutes: [WorkspaceLibraryNativeRoute]
    /// Present only for a connection this workspace holds a definition for.
    public let connection: WorkspaceLibraryMCPConnection?

    public init(
        artifactID: ArtifactID,
        displayName: String,
        kind: ArtifactKind,
        ownership: WorkspaceLibraryOwnership,
        parentPluginLabel: String?,
        declaredName: String?,
        sourceLabel: String?,
        observedDescription: String?,
        includedChildren: [WorkspaceLibraryIncludedItem],
        requestedAssignments: [WorkspaceLibraryRequestedAssignment],
        isAssignable: Bool,
        assignmentExplanation: String?,
        assignableReasons: [WorkspaceLibraryAssignableReason],
        nativeRoutes: [WorkspaceLibraryNativeRoute],
        connection: WorkspaceLibraryMCPConnection? = nil
    ) {
        self.artifactID = artifactID
        self.displayName = displayName
        self.kind = kind
        self.ownership = ownership
        self.parentPluginLabel = parentPluginLabel
        self.declaredName = declaredName
        self.sourceLabel = sourceLabel
        self.observedDescription = observedDescription
        self.includedChildren = includedChildren
        self.requestedAssignments = requestedAssignments
        self.isAssignable = isAssignable
        self.assignmentExplanation = assignmentExplanation
        self.assignableReasons = assignableReasons
        self.nativeRoutes = nativeRoutes
        self.connection = connection
    }
}

public struct WorkspaceLibraryPresetReadModel: Sendable, Equatable, Identifiable {
    public let id: ArtifactID
    public let name: String
    public let revision: UInt64
    public let memberArtifactIDs: [ArtifactID]
}

public struct WorkspaceLibraryProjectReadModel: Sendable, Equatable, Identifiable {
    public let id: ArtifactID
    public let name: String
    public let repositoryHints: [String]
}
