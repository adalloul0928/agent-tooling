import Foundation

public enum WorkspaceMergeConflictKind: String, Hashable, Sendable, CaseIterable {
    /// The same scalar field was changed to different values on both sides.
    case artifactField
    /// Both sides moved the same item to different content.
    case artifactContent
    /// One side deleted an item the other side changed.
    case deleteVersusEdit
    /// Both sides changed who owns an item's content.
    case ownership
    /// Both sides changed a source locator, requested ref or update policy.
    case sourcePolicy
    /// Both sides approved a different upstream revision or content.
    case subscriptionLock
    /// Both sides asked for a different enable/disable state.
    case assignmentEnablement
    /// Both sides described the same contribution differently.
    case assignmentField
    /// Two items would materialize to the same place at one destination.
    case destinationCollision
    /// Both sides renamed or re-rooted the same logical project.
    case projectField
    /// A document version this build cannot merge.
    case unsupportedVersion
    /// The merged graph does not satisfy the workspace contract.
    case invalidResult
}

public struct WorkspaceMergeConflict: Hashable, Sendable {
    public let kind: WorkspaceMergeConflictKind
    public let artifactID: ArtifactID?
    public let objectID: WorkspaceObjectID?
    /// Static description. Never contains a path, endpoint or credential.
    public let detail: String

    public init(
        kind: WorkspaceMergeConflictKind,
        artifactID: ArtifactID? = nil,
        objectID: WorkspaceObjectID? = nil,
        detail: String
    ) {
        self.kind = kind
        self.artifactID = artifactID
        self.objectID = objectID
        self.detail = detail
    }
}

public struct WorkspaceMergeResult: Sendable {
    /// Unsealed. The caller seals it against its own writer and revision.
    public let document: PortableWorkspaceDocument?
    public let conflicts: [WorkspaceMergeConflict]
    /// True when a document was produced and nothing needs a person's decision.
    public var isResolved: Bool { document != nil && conflicts.isEmpty }

    public init(document: PortableWorkspaceDocument?, conflicts: [WorkspaceMergeConflict]) {
        self.document = document
        self.conflicts = conflicts
    }
}

/// Three-way merge of two workspace revisions against their common ancestor.
///
/// It is deliberately pure: no clocks, no filesystem, no device observations.
/// Ancestry and tombstones decide deletion, never wall-clock recency, and an
/// absent ancestor is treated as two independent histories rather than as
/// evidence that either side removed anything.
///
/// A conflict is reported instead of a silent choice whenever both sides moved
/// the same fact in different directions. Every conflicting record is preserved
/// in the result under the local value, so nothing is lost while the person
/// decides; callers must not apply a result that still carries conflicts.
public enum WorkspaceMergeEngine {
    public static func merge(
        base: PortableWorkspaceDocument?,
        local: PortableWorkspaceDocument,
        remote: PortableWorkspaceDocument,
        writerID: WorkspaceObjectID,
        /// Deletions a person explicitly decided not to accept. Only a reviewed
        /// decision may set one aside; nothing here drops one on its own.
        settingAsideDeletionsOf keptItems: Set<ArtifactID> = []
    ) -> WorkspaceMergeResult {
        var conflicts: [WorkspaceMergeConflict] = []
        func conflict(_ kind: WorkspaceMergeConflictKind, _ artifact: ArtifactID?,
                      _ object: WorkspaceObjectID?, _ detail: String) {
            conflicts.append(.init(kind: kind, artifactID: artifact, objectID: object, detail: detail))
        }

        guard local.workspaceID == remote.workspaceID,
              base.map({ $0.workspaceID == local.workspaceID }) ?? true else {
            conflict(.unsupportedVersion, nil, nil, "These revisions belong to different workspaces.")
            return .init(document: nil, conflicts: conflicts)
        }
        let schemaVersion = max(local.schemaVersion, remote.schemaVersion)
        guard schemaVersion <= PortableWorkspaceDocument.currentSchemaVersion else {
            conflict(.unsupportedVersion, nil, nil, "Another Mac wrote a newer workspace format than this app can read.")
            return .init(document: nil, conflicts: conflicts)
        }

        // Deletion is an explicit tombstone, never an absence. Without a common
        // ancestor neither side can be said to have removed anything.
        let candidateTombstones = mergedTombstones(base: base, local: local, remote: remote)
            .filter { !keptItems.contains($0.artifactID) }
        let deleted = Set(candidateTombstones.map(\.artifactID))
        // A record that survives a delete-versus-edit conflict must not also be
        // marked deleted: the pending removal lives in the conflict until the
        // person decides, so no reader sees it as both alive and gone.
        var contested = Set<ArtifactID>()

        var artifacts: [ArtifactRecord] = []
        let artifactKeys = orderedKeys(base?.artifacts, local.artifacts, remote.artifacts) { $0.identity.id }
        let baseArtifacts = index(base?.artifacts) { $0.identity.id }
        let localArtifacts = index(local.artifacts) { $0.identity.id }
        let remoteArtifacts = index(remote.artifacts) { $0.identity.id }
        for id in artifactKeys {
            let ancestor = baseArtifacts[id]
            let mine = localArtifacts[id]
            let theirs = remoteArtifacts[id]
            if deleted.contains(id) {
                // A tombstone plus a change on the other side is the person's
                // decision to make; keep the record until they choose.
                let survivor = mine ?? theirs
                let editedElsewhere = [mine, theirs].contains { record in
                    guard let record else { return false }
                    return ancestor.map { $0 != record } ?? true
                }
                if let survivor, editedElsewhere, ancestor != nil {
                    conflict(.deleteVersusEdit, id, nil, "One Mac removed this item while the other changed it.")
                    artifacts.append(survivor)
                    contested.insert(id)
                }
                continue
            }
            guard let merged = mergeArtifact(ancestor: ancestor, mine: mine, theirs: theirs, report: conflict) else {
                continue
            }
            artifacts.append(merged)
        }

        let sources = mergeCollection(
            base: base?.sources, local: local.sources, remote: remote.sources, key: { $0.id },
            combine: { ancestor, mine, theirs in
                mergeSource(ancestor: ancestor, mine: mine, theirs: theirs, report: conflict)
            })
        let subscriptions = mergeCollection(
            base: base?.subscriptions, local: local.subscriptions, remote: remote.subscriptions, key: { $0.id },
            combine: { ancestor, mine, theirs in
                mergeSubscription(ancestor: ancestor, mine: mine, theirs: theirs, report: conflict)
            })
        let projects = mergeCollection(
            base: base?.logicalProjects, local: local.logicalProjects, remote: remote.logicalProjects, key: { $0.id },
            combine: { ancestor, mine, theirs in
                mergeProject(ancestor: ancestor, mine: mine, theirs: theirs, report: conflict)
            })
        let presets = mergeCollection(
            base: base?.presets, local: local.presets, remote: remote.presets, key: { $0.id },
            combine: { ancestor, mine, theirs in
                mergePreset(ancestor: ancestor, mine: mine, theirs: theirs)
            })
        var assignments = mergeCollection(
            base: base?.assignments, local: local.assignments, remote: remote.assignments, key: { $0.id },
            combine: { ancestor, mine, theirs in
                mergeAssignment(ancestor: ancestor, mine: mine, theirs: theirs, report: conflict)
            })
        // A contribution for an item nobody kept has nothing to deliver.
        let liveArtifacts = Set(artifacts.map(\.identity.id))
        assignments = assignments.filter { liveArtifacts.contains($0.artifactID) }

        reportDestinationCollisions(artifacts: artifacts, assignments: assignments, report: conflict)

        let definitions: [PortableMCPDefinitionRecord]? = schemaVersion >= 3
            ? mergeCollection(
                base: base?.mcpDefinitions, local: local.mcpDefinitions ?? [],
                remote: remote.mcpDefinitions ?? [], key: { $0.artifactID },
                combine: { ancestor, mine, theirs in
                    pick(ancestor: ancestor, mine: mine, theirs: theirs) {
                        conflict(.artifactField, $0.artifactID, nil,
                                 "Both Macs changed this connection's shared definition.")
                    }
                }).filter { liveArtifacts.contains($0.artifactID) }
            : nil

        var document = PortableWorkspaceDocument(
            schemaVersion: schemaVersion,
            minimumReaderVersion: schemaVersion,
            minimumWriterVersion: schemaVersion,
            workspaceID: local.workspaceID,
            // One shared parent when both sides are the same revision.
            revision: .init(parentIDs: Array(Set([local.revision.id, remote.revision.id]))
                                .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString },
                            writerID: writerID),
            artifacts: artifacts,
            sources: sources,
            subscriptions: subscriptions,
            logicalProjects: projects,
            assignments: assignments,
            presets: presets,
            tombstones: candidateTombstones.filter { !contested.contains($0.artifactID) },
            configurationState: schemaVersion >= 2
                ? (local.configurationState ?? remote.configurationState ?? .init()) : nil,
            mcpDefinitions: definitions
        )
        document = document.canonicalized()
        do { try document.validateStructure() }
        catch {
            conflict(.invalidResult, nil, nil, "The combined workspace does not satisfy the workspace contract.")
            return .init(document: nil, conflicts: sorted(conflicts))
        }
        return .init(document: document, conflicts: sorted(conflicts))
    }
}

private extension WorkspaceMergeEngine {
    typealias Report = (WorkspaceMergeConflictKind, ArtifactID?, WorkspaceObjectID?, String) -> Void

    /// Field-wise so an independent rename and content edit combine, while two
    /// different values for one fact stay a decision for the person.
    static func mergeArtifact(
        ancestor: ArtifactRecord?,
        mine: ArtifactRecord?,
        theirs: ArtifactRecord?,
        report: Report
    ) -> ArtifactRecord? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        if mine == theirs { return mine }
        var merged = mine
        let id = mine.identity.id

        merged.identity.displayName = resolve(ancestor?.identity.displayName,
            mine.identity.displayName, theirs.identity.displayName) {
            report(.artifactField, id, nil, "Both Macs renamed this item differently.")
        }
        merged.identity.derivedFrom = resolve(ancestor?.identity.derivedFrom,
            mine.identity.derivedFrom, theirs.identity.derivedFrom) {
            report(.artifactField, id, nil, "Both Macs recorded a different original for this item.")
        }
        merged.declaredName = resolve(ancestor?.declaredName, mine.declaredName, theirs.declaredName) {
            report(.artifactField, id, nil, "Both Macs changed this item's declared name differently.")
        }
        merged.packageRelativePath = resolve(ancestor?.packageRelativePath,
            mine.packageRelativePath, theirs.packageRelativePath) {
            report(.artifactField, id, nil, "Both Macs moved this item inside its package differently.")
        }
        merged.authority = resolve(ancestor?.authority, mine.authority, theirs.authority) {
            report(.ownership, id, nil, "Both Macs changed who owns this item's content.")
        }
        merged.contentDigest = resolve(ancestor?.contentDigest, mine.contentDigest, theirs.contentDigest) {
            report(.artifactContent, id, nil, "Both Macs changed this item's contents.")
        }
        // Aliases and routes are membership records, not one value each.
        merged.identity.aliases = mergeSet(ancestor?.identity.aliases,
            mine.identity.aliases, theirs.identity.aliases)
        merged.nativeRoutes = mergeSet(ancestor?.nativeRoutes, mine.nativeRoutes, theirs.nativeRoutes)
        if mine.identity.kind != theirs.identity.kind {
            report(.artifactField, id, nil, "Both Macs describe this item as a different kind.")
        }
        if mine.identity.parentPackageID != theirs.identity.parentPackageID {
            report(.artifactField, id, nil, "Both Macs place this item in a different package.")
        }
        return merged
    }

    static func mergeSource(
        ancestor: PortableSourceDescriptor?,
        mine: PortableSourceDescriptor?,
        theirs: PortableSourceDescriptor?,
        report: Report
    ) -> PortableSourceDescriptor? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        if mine == theirs { return mine }
        var merged = mine
        merged.repositoryURL = resolve(ancestor?.repositoryURL, mine.repositoryURL, theirs.repositoryURL) {
            report(.sourcePolicy, nil, mine.id, "Both Macs point this source at a different repository.")
        }
        merged.requestedRef = resolve(ancestor?.requestedRef, mine.requestedRef, theirs.requestedRef) {
            report(.sourcePolicy, nil, mine.id, "Both Macs track a different branch or tag for this source.")
        }
        merged.role = resolve(ancestor?.role, mine.role, theirs.role) {
            report(.sourcePolicy, nil, mine.id, "Both Macs changed what this source is used for.")
        }
        merged.packageRelativePaths = mergeSet(ancestor?.packageRelativePaths,
            mine.packageRelativePaths, theirs.packageRelativePaths)
        return merged
    }

    static func mergeSubscription(
        ancestor: UpstreamSubscription?,
        mine: UpstreamSubscription?,
        theirs: UpstreamSubscription?,
        report: Report
    ) -> UpstreamSubscription? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        if mine == theirs { return mine }
        var merged = mine
        merged.sourceID = resolve(ancestor?.sourceID, mine.sourceID, theirs.sourceID) {
            report(.sourcePolicy, mine.artifactID, mine.id, "Both Macs attached this item to a different source.")
        }
        merged.lock = resolve(ancestor?.lock, mine.lock, theirs.lock) {
            report(.subscriptionLock, mine.artifactID, mine.id,
                   "Both Macs approved a different upstream version for this item.")
        }
        return merged
    }

    static func mergeProject(
        ancestor: LogicalProjectRecord?,
        mine: LogicalProjectRecord?,
        theirs: LogicalProjectRecord?,
        report: Report
    ) -> LogicalProjectRecord? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        if mine == theirs { return mine }
        var merged = mine
        merged.name = resolve(ancestor?.name, mine.name, theirs.name) {
            report(.projectField, mine.id, nil, "Both Macs renamed this project differently.")
        }
        merged.repositoryHints = mergeSet(ancestor?.repositoryHints, mine.repositoryHints, theirs.repositoryHints)
        return merged
    }

    /// Membership is a set of records: additions and removals from each side
    /// combine, so one Mac adding a member never resurrects what the other
    /// deliberately removed.
    static func mergePreset(
        ancestor: PresetRecord?,
        mine: PresetRecord?,
        theirs: PresetRecord?
    ) -> PresetRecord? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        if mine == theirs { return mine }
        var merged = mine
        merged.name = mine.name == theirs.name ? mine.name
            : (ancestor?.name == mine.name ? theirs.name : mine.name)
        merged.memberArtifactIDs = mergeSet(ancestor?.memberArtifactIDs,
            mine.memberArtifactIDs, theirs.memberArtifactIDs)
        merged.revision = max(mine.revision, theirs.revision)
        return merged
    }

    static func mergeAssignment(
        ancestor: AssignmentContribution?,
        mine: AssignmentContribution?,
        theirs: AssignmentContribution?,
        report: Report
    ) -> AssignmentContribution? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        if mine == theirs { return mine }
        var merged = mine
        // nil, true and false are three distinct requests; a nil enablement is
        // never treated as agreement with an explicit choice.
        merged.desiredEnabled = resolve(ancestor?.desiredEnabled, mine.desiredEnabled, theirs.desiredEnabled) {
            report(.assignmentEnablement, mine.artifactID, mine.id,
                   "Both Macs asked for a different on or off state here.")
        }
        merged.desiredPresence = resolve(ancestor?.desiredPresence, mine.desiredPresence, theirs.desiredPresence) {
            report(.assignmentEnablement, mine.artifactID, mine.id,
                   "One Mac asked for this item here while the other asked to remove it.")
        }
        merged.destination = resolve(ancestor?.destination, mine.destination, theirs.destination) {
            report(.assignmentField, mine.artifactID, mine.id, "Both Macs changed where this item should go.")
        }
        if mine.reason != theirs.reason {
            report(.assignmentField, mine.artifactID, mine.id, "Both Macs recorded a different reason for this request.")
        }
        if mine.artifactID != theirs.artifactID {
            report(.assignmentField, mine.artifactID, mine.id, "Both Macs point this request at a different item.")
        }
        return merged
    }

    /// Two different items whose declared names differ only by case or Unicode
    /// form would occupy one place. That must be resolved, not raced.
    static func reportDestinationCollisions(
        artifacts: [ArtifactRecord],
        assignments: [AssignmentContribution],
        report: Report
    ) {
        let names = Dictionary(uniqueKeysWithValues: artifacts.map {
            ($0.identity.id, ($0.declaredName ?? $0.identity.displayName)
                .precomposedStringWithCanonicalMapping.lowercased())
        })
        var seen: [String: ArtifactID] = [:]
        var reported = Set<String>()
        for assignment in assignments.sorted(by: { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }) {
            guard let name = names[assignment.artifactID], !name.isEmpty else { continue }
            let key = destinationKey(assignment.destination) + "\u{0}" + name
            guard let existing = seen[key] else { seen[key] = assignment.artifactID; continue }
            guard existing != assignment.artifactID, reported.insert(key).inserted else { continue }
            report(.destinationCollision, assignment.artifactID, assignment.id,
                   "Two items would be installed under the same name at one destination.")
        }
    }

    static func destinationKey(_ destination: PortableDestination) -> String {
        [destination.surface.rawValue, destination.scope.rawValue,
         destination.logicalProjectID?.rawValue.uuidString.lowercased() ?? "-"].joined(separator: "|")
    }

    static func mergedTombstones(
        base: PortableWorkspaceDocument?,
        local: PortableWorkspaceDocument,
        remote: PortableWorkspaceDocument
    ) -> [ArtifactTombstone] {
        var byID: [ArtifactID: ArtifactTombstone] = [:]
        for tombstone in (base?.tombstones ?? []) + local.tombstones + remote.tombstones {
            if var existing = byID[tombstone.artifactID] {
                for alias in tombstone.aliases where !existing.aliases.contains(alias) {
                    existing.aliases.append(alias)
                }
                byID[tombstone.artifactID] = existing
            } else {
                byID[tombstone.artifactID] = tombstone
            }
        }
        return byID.values.sorted { $0.artifactID.rawValue.uuidString < $1.artifactID.rawValue.uuidString }
    }

    static func mergeCollection<Element, Key: Hashable & Comparable>(
        base: [Element]?,
        local: [Element],
        remote: [Element],
        key: (Element) -> Key,
        combine: (Element?, Element?, Element?) -> Element?
    ) -> [Element] {
        let ancestors = index(base, key: key)
        let mine = index(local, key: key)
        let theirs = index(remote, key: key)
        return orderedKeys(base, local, remote, key: key).compactMap {
            combine(ancestors[$0], mine[$0], theirs[$0])
        }
    }

    /// Deterministic regardless of input order, so two Macs merging the same
    /// pair of revisions produce the same bytes.
    static func orderedKeys<Element, Key: Hashable & Comparable>(
        _ base: [Element]?, _ local: [Element], _ remote: [Element], key: (Element) -> Key
    ) -> [Key] {
        var seen = Set<Key>()
        var keys: [Key] = []
        for element in (base ?? []) + local + remote {
            let value = key(element)
            if seen.insert(value).inserted { keys.append(value) }
        }
        return keys.sorted()
    }

    static func index<Element, Key: Hashable>(
        _ elements: [Element]?, key: (Element) -> Key
    ) -> [Key: Element] {
        guard let elements else { return [:] }
        return Dictionary(elements.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Keeps the side that moved. Two different moves are the person's call;
    /// the local value survives so the record is never lost while they decide.
    static func resolve<Value: Equatable>(
        _ ancestor: Value?, _ mine: Value, _ theirs: Value, onConflict: () -> Void
    ) -> Value {
        if mine == theirs { return mine }
        guard let ancestor else { onConflict(); return mine }
        if mine == ancestor { return theirs }
        if theirs == ancestor { return mine }
        onConflict()
        return mine
    }

    static func pick<Element: Equatable>(
        ancestor: Element?, mine: Element?, theirs: Element?, onConflict: (Element) -> Void
    ) -> Element? {
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        if mine == theirs { return mine }
        guard let ancestor else { onConflict(mine); return mine }
        if mine == ancestor { return theirs }
        if theirs == ancestor { return mine }
        onConflict(mine)
        return mine
    }

    static func mergeSet<Element: Hashable>(
        _ ancestor: [Element]?, _ mine: [Element], _ theirs: [Element]
    ) -> [Element] {
        let base = Set(ancestor ?? [])
        let mineSet = Set(mine)
        let theirsSet = Set(theirs)
        let removed = base.subtracting(mineSet).union(base.subtracting(theirsSet))
        let result = mineSet.union(theirsSet).subtracting(removed)
        // Preserve the local order for stability, then append remote additions.
        var ordered = mine.filter(result.contains)
        var seen = Set(ordered)
        for element in theirs where result.contains(element) && seen.insert(element).inserted {
            ordered.append(element)
        }
        return ordered
    }

    static func sorted(_ conflicts: [WorkspaceMergeConflict]) -> [WorkspaceMergeConflict] {
        conflicts.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            let left = $0.artifactID?.rawValue.uuidString ?? ""
            let right = $1.artifactID?.rawValue.uuidString ?? ""
            return left == right ? $0.detail < $1.detail : left < right
        }
    }
}
