import Foundation

/// Brings the library up to date with what a later check of this Mac found.
///
/// A first run records what the scan saw. Every check after it used to update
/// only the marks — where each row was found — and never the rows themselves,
/// so a skill a client gained afterwards was visible to that client and
/// invisible here. This closes that gap with the same rules the first run
/// applies, applied to the difference: a package a client installed is
/// `nativeOwned` with the route it was found under, its members belong to it
/// and share its authority, and everything else is `trackedOnly`.
///
/// It only ever adds. A row already here is left exactly as it is, whatever
/// its authority, and a row somebody removed is not put back. Taking something
/// away because a scan did not see it this time is a decision a person makes,
/// and one a scan that missed a folder would otherwise make for them.
public enum WorkspaceObservationReconciliation {
    /// What one check would add, ready to write.
    public struct Plan: Codable, Hashable, Sendable {
        /// New rows in dependency order: a package before its members.
        public var additions: [ArtifactRecord]
        /// Observed identifiers left out, each with why, so a screen can say
        /// what the check saw and did not record.
        public var skipped: [String]

        public init(additions: [ArtifactRecord] = [], skipped: [String] = []) {
            self.additions = additions
            self.skipped = skipped
        }

        public var isEmpty: Bool { additions.isEmpty }

        public func count(of kind: ArtifactKind) -> Int {
            additions.filter { $0.identity.kind == kind }.count
        }
    }

    /// Decides what a check found that this document does not hold. Pure: it
    /// writes nothing and reads no file.
    public static func plan(
        document: PortableWorkspaceDocument,
        observations: [TargetObservation],
        inventory: ScannedInventory,
        identifiers: () -> ArtifactID = { ArtifactID() }
    ) -> Plan {
        var plan = Plan()
        let live = document.artifacts
        // A row is matched by the name its client knows it by, per kind: a
        // skill and a package can share a name and be different things.
        func existing(_ kind: ArtifactKind, named name: String) -> ArtifactRecord? {
            live.first { $0.identity.kind == kind && $0.declaredName == name }
        }
        let removedPackageAliases = Set(document.tombstones.flatMap(\.aliases))
        func wasRemoved(package id: String) -> Bool {
            ClientKind.allCases.contains { client in
                removedPackageAliases.contains(NativePackageAdoption.pluginAlias(client: client, externalPluginID: id))
            }
        }

        let skillIdentifiers = Set(inventory.skills.map(\.id))
        var memberPaths: [String: String] = [:]
        for observation in observations {
            for (parent, metadata) in observation.pluginMetadata {
                for (child, childMetadata) in observation.skillMetadata
                where childMetadata.providerPluginID == parent {
                    guard let relative = WorkspaceFirstRun.relativeMemberDirectory(
                        childMetadata.path, packageRoot: metadata.source) else { continue }
                    memberPaths[child] = relative
                }
            }
        }

        // Packages first, so a member can name its parent. An existing package
        // keeps its identity and authority; only a new one is decided here.
        var packageIDs: [String: ArtifactID] = [:]
        var authorities: [ArtifactID: ContentAuthority] = [:]
        for artifact in live where artifact.identity.kind == .nativePlugin && artifact.identity.parentPackageID == nil {
            if let name = artifact.declaredName { packageIDs[name] = artifact.identity.id }
            authorities[artifact.identity.id] = artifact.authority
        }
        for plugin in inventory.plugins.sorted(by: { $0.id < $1.id }) where packageIDs[plugin.id] == nil {
            if wasRemoved(package: plugin.id) {
                plan.skipped.append("\(plugin.id): removed from the library before, so it was not put back.")
                continue
            }
            let id = identifiers()
            let routes = observations
                .filter { $0.discoveredPlugins.contains(plugin.id) }
                .compactMap { $0.surface.client }
                .sorted { $0.rawValue < $1.rawValue }
                .map { NativePackageRoute(client: $0, externalPluginID: plugin.id) }
            let members = WorkspaceFirstRun.claimedMembers(of: plugin.id, inventory: inventory, observations: observations)
            let locatable = members.filter { skillIdentifiers.contains($0) }.allSatisfy { memberPaths[$0] != nil }
            let owned = !routes.isEmpty && locatable
            packageIDs[plugin.id] = id
            authorities[id] = owned ? .nativeOwned : .trackedOnly
            plan.additions.append(.init(
                identity: .init(id: id, kind: .nativePlugin, displayName: plugin.name),
                authority: owned ? .nativeOwned : .trackedOnly,
                declaredName: plugin.id, nativeRoutes: owned ? routes : []))
        }

        let bundled = WorkspaceFirstRun.bundledIdentifiers(inventory: inventory, observations: observations)
        for skill in inventory.skills.sorted(by: { $0.id < $1.id }) where existing(.skill, named: skill.id) == nil {
            let parent = WorkspaceFirstRun.parentPackage(
                of: skill.id, inventory: inventory, observations: observations, packageIDs: packageIDs)
            guard parent != nil || !bundled.contains(skill.id) else {
                // Bundled but with no single package to belong to: not a
                // standalone thing, and not something to guess a parent for.
                plan.skipped.append("\(skill.id): more than one package claims it, so it belongs to neither.")
                continue
            }
            let authority = parent.flatMap { authorities[$0] } ?? .trackedOnly
            var path: String?
            if authority == .nativeOwned {
                // A native-owned member has to say where it lives inside its
                // package. One this check could not place is left out rather
                // than written as a claim with nothing behind it.
                guard let located = memberPaths[skill.id] else {
                    plan.skipped.append("\(skill.id): its package owns it, but the check could not say where inside it.")
                    continue
                }
                path = located
            }
            plan.additions.append(.init(
                identity: .init(id: identifiers(), kind: .skill, displayName: skill.displayName, parentPackageID: parent),
                authority: authority, declaredName: skill.id, packageRelativePath: path))
        }

        for server in inventory.mcpServers.sorted(by: { $0.id < $1.id }) where existing(.mcpServer, named: server.id) == nil {
            let parent = WorkspaceFirstRun.parentPackage(
                of: server.id, inventory: inventory, observations: observations, packageIDs: packageIDs)
            guard parent != nil || !bundled.contains(server.id) else {
                plan.skipped.append("\(server.id): more than one package claims it, so it belongs to neither.")
                continue
            }
            plan.additions.append(.init(
                identity: .init(id: identifiers(), kind: .mcpServer, displayName: server.name, parentPackageID: parent),
                authority: parent.flatMap { authorities[$0] } ?? .trackedOnly, declaredName: server.id))
        }
        return plan
    }
}

/// Writes one plan under the same head check as every other command.
///
/// The plan is decided against one revision and applied against the head it
/// names. Anything the head already holds by the time it lands — another
/// writer added the same row — is left alone rather than duplicated, and a
/// member whose package did not land is left out with it.
public struct WorkspaceObservationReconciliationCommand: Codable, Sendable, Equatable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let plan: WorkspaceObservationReconciliation.Plan

    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        plan: WorkspaceObservationReconciliation.Plan
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.plan = plan
    }

    func inputDigest() -> String {
        var fields = [
            "observation-reconciliation.v1",
            expectedRevisionID.rawValue.uuidString.lowercased(),
            idempotencyKey.rawValue.uuidString.lowercased(),
        ]
        for addition in plan.additions {
            fields.append(addition.identity.id.rawValue.uuidString.lowercased())
            fields.append(addition.identity.kind.rawValue)
            fields.append(addition.declaredName ?? "")
            fields.append(addition.identity.parentPackageID?.rawValue.uuidString.lowercased() ?? "")
            fields.append(addition.packageRelativePath ?? "")
            fields.append(String(describing: addition.authority))
        }
        return framedDigest(fields: fields)
    }

    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        var written: [ArtifactID] = []
        var landed: Set<ArtifactID> = []
        for addition in plan.additions {
            let duplicateName = document.artifacts.contains {
                $0.identity.kind == addition.identity.kind && $0.declaredName == addition.declaredName
            }
            let duplicateID = document.artifacts.contains { $0.identity.id == addition.identity.id }
                || document.tombstones.contains { $0.artifactID == addition.identity.id }
            guard !duplicateName, !duplicateID else { continue }
            if let parent = addition.identity.parentPackageID {
                // A member lands only under a package that is here: the one
                // this plan wrote, or one that was here already.
                guard landed.contains(parent) || document.artifacts.contains(where: { $0.identity.id == parent })
                else { continue }
            }
            document.artifacts.append(addition)
            landed.insert(addition.identity.id)
            written.append(addition.identity.id)
        }
        return written
    }
}

extension WorkspaceApplicationService {
    /// Adds what a check of this Mac found and this library did not hold.
    ///
    /// One metadata write under the head check every command shares. It runs
    /// no client tool, writes no file a client owns, touches no device state,
    /// and never changes a row that was already here. A plan with nothing to
    /// add is refused rather than committed as an empty revision.
    public func reconcileObservedInventory(
        _ command: WorkspaceObservationReconciliationCommand
    ) throws -> WorkspaceCommandReceipt {
        try Task.checkCancellation()
        guard !command.plan.isEmpty else { throw WorkspaceObservationReconciliationError.nothingToAdd }
        return try store.commitMetadata(
            expectedRevisionID: command.expectedRevisionID,
            idempotencyKey: command.idempotencyKey,
            inputDigest: command.inputDigest(),
            writerID: writerID
        ) { document in
            try command.apply(to: &document)
        }
    }
}

public enum WorkspaceObservationReconciliationError: LocalizedError, Equatable, Sendable {
    case nothingToAdd

    public var errorDescription: String? {
        switch self {
        case .nothingToAdd: "The check found nothing this library does not already hold."
        }
    }
}
