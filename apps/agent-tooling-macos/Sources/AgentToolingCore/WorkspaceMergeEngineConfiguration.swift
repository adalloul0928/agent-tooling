import Foundation

/// The parts of a merge that this packet made writable: the catalog list inside
/// the configuration supplement, the check that two Macs did not each record
/// the same app package as a separate library item, and the two checks that
/// name what happens when both Macs act on one item's upstream link.
///
/// It lives beside the engine rather than inside it so that four commands being
/// built at once do not queue behind one file. The rules are the engine's own:
/// ancestry decides removal, a value moved on both sides is the person's
/// decision, and nothing is chosen by recency.
extension WorkspaceMergeEngine {
    /// True when at least one collision was reported.
    static func reportNativeRouteCollisions(artifacts: [ArtifactRecord], report: Report) -> Bool {
        var owners: [NativePackageRoute: ArtifactID] = [:]
        var reported = false
        for artifact in artifacts.sorted(by: { $0.identity.id < $1.identity.id }) {
            for route in artifact.nativeRoutes.sorted(by: {
                $0.client == $1.client
                    ? $0.externalPluginID < $1.externalPluginID : $0.client.rawValue < $1.client.rawValue
            }) {
                guard let existing = owners[route] else {
                    owners[route] = artifact.identity.id
                    continue
                }
                guard existing != artifact.identity.id else { continue }
                report(
                    .nativeRouteCollision, artifact.identity.id, nil,
                    "Both Macs added the same app package to the library separately.")
                reported = true
            }
        }
        return reported
    }

    /// A subscription is a statement about one item: the item's authority names
    /// it, and its lock approves the bytes that item holds. Two Macs that each
    /// linked the same item wrote two subscriptions for it, and the merged
    /// authority — kept local, like every other contested value — names one.
    ///
    /// The unnamed one is set aside instead of being carried into a document
    /// that cannot be validated. Nothing is lost by that: the Mac that wrote it
    /// still holds its own revision, and the conflict names the item so the
    /// person can drop one side there. Returns the subscriptions that survive.
    static func reportSubscriptionOwnerCollisions(
        artifacts: [ArtifactRecord],
        subscriptions: [UpstreamSubscription],
        report: Report
    ) -> [UpstreamSubscription] {
        let owners = index(artifacts, key: { $0.identity.id })
        return subscriptions.filter { subscription in
            // An item nobody kept is not this check's business; the contract's
            // own validation still has the last word on that.
            guard let owner = owners[subscription.artifactID] else { return true }
            switch owner.authority {
            case .centralUpstream(let subscriptionID) where subscriptionID == subscription.id:
                return true
            case .centralUpstream:
                report(
                    .subscriptionOwnerCollision, subscription.artifactID, subscription.id,
                    "Both Macs made this skill follow a repository separately.")
                return false
            default:
                // The item follows nothing now, so this has nothing left to
                // approve — the rule that drops a contribution for an item
                // nobody kept, applied to the record that says where an item's
                // next version comes from.
                return false
            }
        }
    }

    /// One Mac linked an item while the other edited it. Each side moved one
    /// fact only, so the ordinary rules take the new authority *and* the new
    /// bytes, and the lock is left approving a version nobody holds — which
    /// would deploy content nobody reviewed.
    ///
    /// The approved digest is put back, because it is the one value already
    /// present in the inputs and it keeps the record honest about where the
    /// content came from. The conflict says what happened, and nothing is
    /// applied while it stands: resolving it keeps either the followed version
    /// or the edit, and choosing the edit takes the subscription with it.
    static func reportSubscriptionContentMismatches(
        artifacts: inout [ArtifactRecord],
        subscriptions: [UpstreamSubscription],
        report: Report
    ) {
        for subscription in subscriptions {
            guard let position = artifacts.firstIndex(where: { $0.identity.id == subscription.artifactID }),
                let held = artifacts[position].contentDigest,
                held != subscription.lock.approvedContent
            else { continue }
            report(
                .subscriptionContentMismatch, subscription.artifactID, subscription.id,
                "One Mac made this skill follow a repository while the other changed its files.")
            artifacts[position].contentDigest = subscription.lock.approvedContent
        }
    }

    /// Only the catalog list is combined. Every other part of the configuration
    /// supplement keeps the behaviour it had: the local side is taken whole,
    /// because nothing writes those records and a merge nobody exercises is a
    /// merge nobody has checked.
    ///
    /// Catalogs are combined the way preset membership is — against the common
    /// ancestor, so one Mac adding a catalog cannot bring back one the other
    /// removed, and a removal on one side with a change on the other is the
    /// person's decision rather than a silent win for either.
    static func mergeConfigurationState(
        base: WorkspaceConfigurationState?,
        local: WorkspaceConfigurationState?,
        remote: WorkspaceConfigurationState?,
        report: Report
    ) -> WorkspaceConfigurationState {
        guard var merged = local ?? remote else { return .init() }
        guard let local, let remote, local.catalogSources != remote.catalogSources else { return merged }
        let ancestors = index(base?.catalogSources, key: { $0.id })
        let mine = index(local.catalogSources, key: { $0.id })
        let theirs = index(remote.catalogSources, key: { $0.id })
        var sources: [WorkspaceCatalogSourceRecord] = []
        for id in orderedKeys(base?.catalogSources, local.catalogSources, remote.catalogSources, key: { $0.id }) {
            let ancestor = ancestors[id]
            switch (mine[id], theirs[id]) {
            case (nil, nil):
                continue
            case (let record?, nil), (nil, let record?):
                // Absent on one side with an ancestor is a removal there;
                // absent with no ancestor is an addition on the other.
                guard let ancestor else {
                    sources.append(record)
                    continue
                }
                if ancestor != record {
                    report(
                        .catalogSource, nil, id,
                        "One Mac removed this catalog while the other changed it.")
                    sources.append(record)
                }
            case (let mineRecord?, let theirsRecord?):
                sources.append(
                    mergeCatalogSource(
                        ancestor: ancestor, mine: mineRecord, theirs: theirsRecord, report: report))
            }
        }
        merged.catalogSources = sources
        // An allocation without its record fails validation, and a record
        // without its allocation does too, so the two move together.
        let live = Set(sources.map(\.id))
        var allocations = merged.identityMap.filter {
            $0.legacy.domain != .catalogSource || live.contains($0.objectID)
        }
        let known = Set(allocations.map(\.legacy))
        for allocation in (local.identityMap + remote.identityMap)
        where allocation.legacy.domain == .catalogSource && live.contains(allocation.objectID)
            && !known.contains(allocation.legacy)
            && !allocations.contains(where: { $0.objectID == allocation.objectID })
        {
            allocations.append(allocation)
        }
        merged.identityMap = allocations
        return merged
    }

    static func mergeCatalogSource(
        ancestor: WorkspaceCatalogSourceRecord?,
        mine: WorkspaceCatalogSourceRecord,
        theirs: WorkspaceCatalogSourceRecord,
        report: Report
    ) -> WorkspaceCatalogSourceRecord {
        if mine == theirs { return mine }
        var merged = mine
        merged.name = resolve(ancestor?.name, mine.name, theirs.name) {
            report(.catalogSource, nil, mine.id, "Both Macs named this catalog differently.")
        }
        merged.kind = resolve(ancestor?.kind, mine.kind, theirs.kind) {
            report(.catalogSource, nil, mine.id, "Both Macs describe this catalog as a different kind.")
        }
        merged.remoteLocation = resolve(ancestor?.remoteLocation, mine.remoteLocation, theirs.remoteLocation) {
            report(.catalogSource, nil, mine.id, "Both Macs point this catalog at a different address.")
        }
        merged.isOptionalBackup = resolve(
            ancestor?.isOptionalBackup, mine.isOptionalBackup, theirs.isOptionalBackup
        ) {
            report(.catalogSource, nil, mine.id, "Both Macs changed whether this catalog is an optional backup.")
        }
        return merged
    }
}
