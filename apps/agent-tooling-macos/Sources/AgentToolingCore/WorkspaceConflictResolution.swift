import Foundation

/// Which side of a conflict the person chose.
public enum WorkspaceConflictChoice: String, Hashable, Sendable, CaseIterable {
    /// Keep what this Mac has.
    case keepLocal
    /// Take what the other Mac has.
    case takeRemote
}

/// One decision, bound to the exact conflict it answers.
public struct WorkspaceConflictResolution: Hashable, Sendable {
    public let kind: WorkspaceMergeConflictKind
    public let artifactID: ArtifactID?
    public let objectID: WorkspaceObjectID?
    public let choice: WorkspaceConflictChoice

    public init(
        kind: WorkspaceMergeConflictKind,
        artifactID: ArtifactID? = nil,
        objectID: WorkspaceObjectID? = nil,
        choice: WorkspaceConflictChoice
    ) {
        self.kind = kind
        self.artifactID = artifactID
        self.objectID = objectID
        self.choice = choice
    }

    func answers(_ conflict: WorkspaceMergeConflict) -> Bool {
        kind == conflict.kind && artifactID == conflict.artifactID && objectID == conflict.objectID
    }
}

public struct WorkspaceConflictResolutionResult: Sendable {
    public let document: PortableWorkspaceDocument?
    /// Conflicts still waiting for a decision.
    public let remaining: [WorkspaceMergeConflict]
    public var isResolved: Bool { document != nil && remaining.isEmpty }
}

/// Applies a person's conflict decisions by re-running the merge with the
/// chosen side treated as the one that moved.
///
/// It never invents a third value and never resolves anything it was not asked
/// about: a conflict with no decision stays a conflict, and the result is only
/// usable when every one of them has an answer. Choosing a side is expressed by
/// rewriting the *ancestor* for that fact, so the engine's own rules still
/// decide the outcome rather than this type editing the document directly.
public enum WorkspaceConflictResolver {
    public static func resolve(
        base: PortableWorkspaceDocument?,
        local: PortableWorkspaceDocument,
        remote: PortableWorkspaceDocument,
        conflicts: [WorkspaceMergeConflict],
        resolutions: [WorkspaceConflictResolution],
        writerID: WorkspaceObjectID
    ) -> WorkspaceConflictResolutionResult {
        let unanswered = conflicts.filter { conflict in
            !resolutions.contains { $0.answers(conflict) }
        }
        guard unanswered.isEmpty else { return .init(document: nil, remaining: unanswered) }

        // Pretend the unchosen side never moved, so the engine sees one change
        // instead of two and applies its ordinary combining rules.
        var adjusted = base ?? local
        if base == nil { adjusted = local }
        var keptItems = Set<ArtifactID>()
        for resolution in resolutions {
            let loser = resolution.choice == .keepLocal ? remote : local
            adjust(&adjusted, away: loser, resolution: resolution)
            if resolution.kind == .deleteVersusEdit, resolution.choice == .keepLocal,
               let id = resolution.artifactID {
                keptItems.insert(id)
            }
        }
        let merge = WorkspaceMergeEngine.merge(base: adjusted, local: local, remote: remote,
                                               writerID: writerID, settingAsideDeletionsOf: keptItems)
        return .init(document: merge.document, remaining: merge.conflicts)
    }
}

private extension WorkspaceConflictResolver {
    /// Moves the ancestor's value for one fact onto the side that is being set
    /// aside, which makes the chosen side the only one that changed.
    static func adjust(
        _ ancestor: inout PortableWorkspaceDocument,
        away loser: PortableWorkspaceDocument,
        resolution: WorkspaceConflictResolution
    ) {
        switch resolution.kind {
        case .artifactField, .artifactContent, .ownership, .projectField:
            guard let id = resolution.artifactID,
                  let losing = loser.artifacts.first(where: { $0.identity.id == id }) else { return }
            if let index = ancestor.artifacts.firstIndex(where: { $0.identity.id == id }) {
                ancestor.artifacts[index] = losing
            } else {
                ancestor.artifacts.append(losing)
            }
            if resolution.kind == .projectField,
               let project = loser.logicalProjects.first(where: { $0.id == id }) {
                if let index = ancestor.logicalProjects.firstIndex(where: { $0.id == id }) {
                    ancestor.logicalProjects[index] = project
                } else {
                    ancestor.logicalProjects.append(project)
                }
            }

        case .deleteVersusEdit:
            // Accepting the removal means the edit must look like it never
            // happened; keeping the item is handled by setting the deletion
            // aside in the merge itself.
            guard resolution.choice == .takeRemote, let id = resolution.artifactID,
                  let losing = loser.artifacts.first(where: { $0.identity.id == id }) else { return }
            if let index = ancestor.artifacts.firstIndex(where: { $0.identity.id == id }) {
                ancestor.artifacts[index] = losing
            } else {
                ancestor.artifacts.append(losing)
            }

        case .sourcePolicy, .subscriptionLock:
            guard let id = resolution.objectID else { return }
            if let losing = loser.sources.first(where: { $0.id == id }) {
                if let index = ancestor.sources.firstIndex(where: { $0.id == id }) {
                    ancestor.sources[index] = losing
                } else {
                    ancestor.sources.append(losing)
                }
            }
            if let losing = loser.subscriptions.first(where: { $0.id == id }) {
                if let index = ancestor.subscriptions.firstIndex(where: { $0.id == id }) {
                    ancestor.subscriptions[index] = losing
                } else {
                    ancestor.subscriptions.append(losing)
                }
            }

        case .assignmentEnablement, .assignmentField:
            guard let id = resolution.objectID,
                  let losing = loser.assignments.first(where: { $0.id == id }) else { return }
            if let index = ancestor.assignments.firstIndex(where: { $0.id == id }) {
                ancestor.assignments[index] = losing
            } else {
                ancestor.assignments.append(losing)
            }

        case .catalogSource:
            guard let id = resolution.objectID else { return }
            var state = ancestor.configurationState ?? .init()
            let losing = loser.configurationState?.catalogSources.first { $0.id == id }
            // A catalog the losing side removed has to disappear from the
            // ancestor too, or the merge would read the chosen side's record as
            // untouched rather than as the addition it now is.
            if let losing {
                if let index = state.catalogSources.firstIndex(where: { $0.id == id }) {
                    state.catalogSources[index] = losing
                } else {
                    state.catalogSources.append(losing)
                }
                let allocated = state.identityMap.contains {
                    $0.legacy.domain == .catalogSource && $0.objectID == id
                }
                let losingAllocation = loser.configurationState.flatMap {
                    WorkspaceCatalogSourceIdentity.entry(for: id, in: $0)
                }
                if !allocated, let losingAllocation {
                    state.identityMap.append(losingAllocation)
                }
            } else {
                state.catalogSources.removeAll { $0.id == id }
                state.identityMap.removeAll { $0.legacy.domain == .catalogSource && $0.objectID == id }
            }
            ancestor.configurationState = state

        case .destinationCollision, .nativeRouteCollision, .unsupportedVersion, .invalidResult:
            // These are not "pick a side" conflicts. A colliding destination
            // needs different intent, two records of one app package need one
            // of them removed, and an unreadable or invalid document cannot be
            // fixed by choosing one of two Macs.
            break
        }
    }
}
