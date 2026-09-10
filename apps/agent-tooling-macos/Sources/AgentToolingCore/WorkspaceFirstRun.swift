import Foundation

/// Creates a versioned workspace from what is actually installed on this Mac.
///
/// This is how a workspace begins when there is nothing to begin from. It scans
/// the clients, records what it finds, and writes the first revision. It is not
/// a migration: nothing is read from another store, and nothing is claimed to be
/// owned by this app.
///
/// Everything discovered is recorded the way a scan can honestly support it. A
/// package a client installed is `nativeOwned` with the route it was found
/// under, because that client owns it and will keep owning it. Everything else
/// is `trackedOnly`: this workspace knows the item exists and where it is, and
/// claims no authority over its content. Nothing becomes `centralPersonal` from
/// a scan — taking ownership of somebody's files is a decision they make, not
/// one a first launch makes for them.
public enum WorkspaceFirstRun {
    public struct Result: Sendable {
        public let document: PortableWorkspaceDocument
        public let device: DeviceWorkspaceState
        public let skillCount: Int
        public let packageCount: Int
        public let connectionCount: Int
    }

    /// Builds the first revision from a completed scan. Pure: it writes nothing.
    public static func prepare(
        observations: [TargetObservation],
        inventory: ScannedInventory,
        workspaceID: WorkspaceObjectID = WorkspaceObjectID(),
        deviceID: WorkspaceObjectID = WorkspaceObjectID(),
        writerID: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> Result {
        var artifacts: [ArtifactRecord] = []
        var packageIDs: [String: ArtifactID] = [:]
        var memberPaths: [String: String] = [:]
        let skillIdentifiers = Set(inventory.skills.map(\.id))
        for observation in observations {
            for (parent, metadata) in observation.pluginMetadata {
                for (child, childMetadata) in observation.skillMetadata
                where childMetadata.providerPluginID == parent {
                    guard let relative = relativeMemberDirectory(
                        childMetadata.path, packageRoot: metadata.source) else { continue }
                    memberPaths[child] = relative
                }
            }
        }

        // Packages first, so a member can name its parent.
        for plugin in inventory.plugins.sorted(by: { $0.id < $1.id }) {
            let id = ArtifactID()
            packageIDs[plugin.id] = id
            let routes = observations
                .filter { $0.discoveredPlugins.contains(plugin.id) }
                .compactMap { $0.surface.client }
                .sorted { $0.rawValue < $1.rawValue }
                .map { NativePackageRoute(client: $0, externalPluginID: plugin.id) }
            // A route the scan saw makes this the client's. So does knowing
            // where each of its skills lives inside it — without that, there is
            // no located member file, and claiming the client owns something
            // this build cannot point at would be a claim with nothing behind
            // it. Either gap makes the package a record and nothing more.
            let members = claimedMembers(of: plugin.id, inventory: inventory,
                                         observations: observations)
            let locatable = members.filter { skillIdentifiers.contains($0) }
                .allSatisfy { memberPaths[$0] != nil }
            artifacts.append(.init(
                identity: .init(id: id, kind: .nativePlugin, displayName: plugin.name),
                authority: routes.isEmpty || !locatable ? .trackedOnly : .nativeOwned,
                declaredName: plugin.id, nativeRoutes: routes.isEmpty || !locatable ? [] : routes))
        }

        // A member's authority is its parent's. The package owns it either way,
        // and a child that claimed a different authority from the thing that
        // delivers it would make two things responsible for one file.
        let authorities = Dictionary(artifacts.map { ($0.identity.id, $0.authority) },
                                     uniquingKeysWith: { first, _ in first })
        let bundled = bundledIdentifiers(inventory: inventory, observations: observations)
        for skill in inventory.skills.sorted(by: { $0.id < $1.id }) {
            let parent = parentPackage(of: skill.id, inventory: inventory,
                                       observations: observations, packageIDs: packageIDs)
            // Bundled but with no single package claiming it: recorded as
            // nothing rather than as a standalone thing it is not.
            guard parent != nil || !bundled.contains(skill.id) else { continue }
            artifacts.append(.init(
                identity: .init(id: ArtifactID(), kind: .skill,
                                displayName: skill.displayName, parentPackageID: parent),
                authority: parent.flatMap { authorities[$0] } ?? .trackedOnly,
                declaredName: skill.id,
                // A native-owned member has to say where it lives inside its
                // package; only an MCP declaration may omit one.
                packageRelativePath: parent.flatMap { authorities[$0] } == .nativeOwned
                    ? memberPaths[skill.id] : nil))
        }
        for server in inventory.mcpServers.sorted(by: { $0.id < $1.id }) {
            let parent = parentPackage(of: server.id, inventory: inventory,
                                       observations: observations, packageIDs: packageIDs)
            guard parent != nil || !bundled.contains(server.id) else { continue }
            artifacts.append(.init(
                identity: .init(id: ArtifactID(), kind: .mcpServer,
                                displayName: server.name, parentPackageID: parent),
                authority: parent.flatMap { authorities[$0] } ?? .trackedOnly,
                declaredName: server.id))
        }

        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: workspaceID, revision: .init(writerID: writerID), artifacts: artifacts))
        var device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
        device.observations = observations.sorted { $0.surface.rawValue < $1.surface.rawValue }
        // What each client that answered can be asked to carry, from the same
        // scan. Without it a brand-new workspace could record an assignment and
        // then refuse to plan it, because the check that admits a destination
        // would have nothing to read.
        device.capabilityEvidence = TargetCapabilityEvidence.derive(from: observations)
        try document.validateStructure()
        try device.validateStructure(against: document)

        return .init(
            document: document, device: device,
            skillCount: artifacts.filter { $0.identity.kind == .skill }.count,
            packageCount: artifacts.filter { $0.identity.kind == .nativePlugin }.count,
            connectionCount: artifacts.filter { $0.identity.kind == .mcpServer }.count)
    }

    /// Scans, prepares and writes the first revision into a new store.
    ///
    /// Refuses a store that already holds a workspace: a first run is only ever
    /// first, and starting over on top of an existing one would discard whatever
    /// that workspace had decided.
    @discardableResult
    public static func begin(
        containerRoot: URL,
        homeURL: URL,
        runner: any CommandRunning,
        registry: ClientAdapterRegistry = ClientAdapterRegistry(),
        clients: Set<ClientKind> = Set(ClientKind.allCases)
    ) async throws -> (store: WorkspaceRevisionStore, result: Result) {
        let observations = await registry.scanAll(homeURL: homeURL, runner: runner, clients: clients)
        let inventory = InventoryCompiler.compile(observations: observations, homeURL: homeURL)
        let prepared = try prepare(observations: observations, inventory: inventory)
        let store = try WorkspaceRevisionStore(
            containerRoot: containerRoot, workspaceID: prepared.document.workspaceID,
            deviceID: prepared.device.deviceID)
        guard try store.snapshot() == nil else {
            throw WorkspaceRevisionStoreError.alreadyInitialized
        }
        try store.initialize(document: prepared.document, device: prepared.device)
        return (store, prepared)
    }

    /// Everything this package claims, by its own record or by what a client
    /// reported.
    private static func claimedMembers(
        of packageID: String, inventory: ScannedInventory, observations: [TargetObservation]
    ) -> Set<String> {
        var members = Set(inventory.plugins.first { $0.id == packageID }?.skills ?? [])
        for observation in observations {
            if let metadata = observation.pluginMetadata[packageID] {
                members.formUnion(metadata.skillIDs)
                members.formUnion(metadata.mcpServerIDs)
            }
            for (child, metadata) in observation.skillMetadata
            where metadata.providerPluginID == packageID {
                members.insert(child)
            }
        }
        return members
    }

    static func relativeMemberDirectory(_ path: String, packageRoot: String) -> String? {
        guard path.hasPrefix("/"), packageRoot.hasPrefix("/"),
              !path.contains("\0"), !packageRoot.contains("\0") else { return nil }
        let root = URL(fileURLWithPath: packageRoot).standardizedFileURL
        var child = URL(fileURLWithPath: path).standardizedFileURL
        if child.lastPathComponent == "SKILL.md" { child.deleteLastPathComponent() }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard child.path.hasPrefix(prefix) else { return nil }
        let relative = String(child.path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// Every identifier some package claims, by its own record or by what a
    /// client reported.
    static func bundledIdentifiers(
        inventory: ScannedInventory, observations: [TargetObservation]
    ) -> Set<String> {
        var bundled = Set(inventory.plugins.flatMap(\.skills))
        for observation in observations {
            for (id, metadata) in observation.skillMetadata where metadata.providerPluginID != nil {
                bundled.insert(id)
            }
            for metadata in observation.pluginMetadata.values {
                bundled.formUnion(metadata.skillIDs)
                bundled.formUnion(metadata.mcpServerIDs)
            }
        }
        return bundled
    }

    /// The one package that claims this item, or `nil`.
    ///
    /// Two packages claiming one item is not a parent to pick between, so it is
    /// recorded as belonging to neither rather than arbitrarily to one.
    private static func parentPackage(
        of identifier: String,
        inventory: ScannedInventory,
        observations: [TargetObservation],
        packageIDs: [String: ArtifactID]
    ) -> ArtifactID? {
        var claimants = Set(inventory.plugins.filter { $0.skills.contains(identifier) }.map(\.id))
        for observation in observations {
            if let parent = observation.skillMetadata[identifier]?.providerPluginID {
                claimants.insert(parent)
            }
            for (parent, metadata) in observation.pluginMetadata
            where metadata.skillIDs.contains(identifier) || metadata.mcpServerIDs.contains(identifier) {
                claimants.insert(parent)
            }
        }
        guard claimants.count == 1, let only = claimants.first else { return nil }
        return packageIDs[only]
    }
}
