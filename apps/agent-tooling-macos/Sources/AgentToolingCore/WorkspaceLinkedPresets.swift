import CryptoKit
import Foundation

/// A standing subscription to one preset's membership at the destinations the
/// person chose when they linked it.
///
/// This is separate from applying a preset once. Applying once materializes
/// explicit assignments and then forgets the preset; a subscription keeps
/// following it, and owns only what it contributed.
public struct LinkedPresetSubscription: Codable, Hashable, Sendable {
    public let presetID: ArtifactID
    /// The membership revision this device has already applied.
    public let appliedRevision: UInt64
    /// Where this subscription places members. Chosen when linking, not derived
    /// from whatever the preset happens to contain.
    public let destinations: [PortableDestination]

    public init(presetID: ArtifactID, appliedRevision: UInt64, destinations: [PortableDestination]) {
        self.presetID = presetID
        self.appliedRevision = appliedRevision
        self.destinations = destinations
    }
}

/// One change a linked preset would make, shown before anything moves.
public struct LinkedPresetChange: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case add
        /// The preset dropped this member, so its own contribution goes.
        case removeContribution
        /// The member left the preset, but something else still requires it
        /// here, so nothing is removed.
        case retainedByOtherReason
    }
    public let kind: Kind
    public let presetID: ArtifactID
    public let artifactID: ArtifactID
    public let destination: PortableDestination
    /// Reasons that keep this destination even after the preset lets go.
    public let remainingReasons: [AssignmentReason]
}

public struct LinkedPresetUpdate: Sendable {
    public let presetID: ArtifactID
    public let fromRevision: UInt64
    public let toRevision: UInt64
    public let changes: [LinkedPresetChange]
    public var hasPendingChanges: Bool { changes.contains { $0.kind != .retainedByOtherReason } }
}

/// Works out what a linked preset would change, and applies only that.
///
/// A subscription owns exactly the contributions it made. Removing a member
/// never removes a manual assignment or one another preset also requires; those
/// destinations are reported as retained, so the person can see that letting go
/// changed nothing there. Nothing is applied until the pending changes have been
/// shown.
public enum WorkspaceLinkedPresetResolver {
    /// What would change if this subscription caught up with the preset.
    public static func pendingUpdate(
        for subscription: LinkedPresetSubscription,
        in document: PortableWorkspaceDocument
    ) -> LinkedPresetUpdate? {
        guard let preset = document.presets.first(where: { $0.id == subscription.presetID }) else { return nil }
        let members = Set(preset.memberArtifactIDs)
        let live = Set(document.artifacts.filter { $0.identity.parentPackageID == nil }.map(\.identity.id))
        let mine = document.assignments.filter { $0.reason == .preset(presetID: subscription.presetID) }

        var changes: [LinkedPresetChange] = []
        for destination in subscription.destinations.sorted(by: order) {
            let existing = Set(mine.filter { $0.destination == destination }.map(\.artifactID))
            for artifactID in members.subtracting(existing).sorted(by: idOrder) where live.contains(artifactID) {
                changes.append(.init(kind: .add, presetID: subscription.presetID, artifactID: artifactID,
                                     destination: destination, remainingReasons: []))
            }
            for artifactID in existing.subtracting(members).sorted(by: idOrder) {
                // Anything else asking for this destination keeps it.
                let others = document.assignments.filter {
                    $0.artifactID == artifactID && $0.destination == destination
                        && $0.reason != .preset(presetID: subscription.presetID)
                }.map(\.reason)
                changes.append(.init(
                    kind: others.isEmpty ? .removeContribution : .retainedByOtherReason,
                    presetID: subscription.presetID, artifactID: artifactID,
                    destination: destination, remainingReasons: others))
            }
        }
        return .init(presetID: subscription.presetID, fromRevision: subscription.appliedRevision,
                     toRevision: preset.revision, changes: changes)
    }

    /// Applies exactly the reviewed changes. A destination another reason still
    /// requires keeps its other contribution untouched.
    public static func apply(
        _ update: LinkedPresetUpdate,
        to document: inout PortableWorkspaceDocument,
        identifiers: () -> WorkspaceObjectID = { WorkspaceObjectID() }
    ) -> [ArtifactID] {
        var affected: [ArtifactID] = []
        for change in update.changes {
            switch change.kind {
            case .add:
                let contribution = AssignmentContribution(
                    id: identifiers(), artifactID: change.artifactID, destination: change.destination,
                    reason: .preset(presetID: change.presetID), desiredPresence: true)
                guard !document.assignments.contains(where: {
                    $0.artifactID == contribution.artifactID && $0.destination == contribution.destination
                        && $0.reason == contribution.reason
                }) else { continue }
                document.assignments.append(contribution)
                affected.append(change.artifactID)
            case .removeContribution, .retainedByOtherReason:
                // Only this preset's own contribution is ever removed.
                let before = document.assignments.count
                document.assignments.removeAll {
                    $0.artifactID == change.artifactID && $0.destination == change.destination
                        && $0.reason == .preset(presetID: change.presetID)
                }
                if document.assignments.count != before { affected.append(change.artifactID) }
            }
        }
        return Array(Set(affected)).sorted(by: idOrder)
    }

    /// Names every change that was shown, so a repeat of the same reviewed
    /// catch-up replays and a different one does not.
    public static func inputDigest(_ update: LinkedPresetUpdate) -> String {
        var fields = ["linked-preset.catch-up.v1",
                      update.presetID.rawValue.uuidString.lowercased(),
                      String(update.fromRevision), String(update.toRevision)]
        for change in update.changes {
            fields += [change.kind.rawValue,
                       change.artifactID.rawValue.uuidString.lowercased(),
                       change.destination.surface.rawValue,
                       change.destination.scope.rawValue,
                       change.destination.logicalProjectID?.rawValue.uuidString.lowercased() ?? ""]
        }
        let payload = Data(fields.joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

private extension WorkspaceLinkedPresetResolver {
    static func order(_ lhs: PortableDestination, _ rhs: PortableDestination) -> Bool {
        let left = [lhs.surface.rawValue, lhs.scope.rawValue,
                    lhs.logicalProjectID?.rawValue.uuidString ?? ""]
        let right = [rhs.surface.rawValue, rhs.scope.rawValue,
                     rhs.logicalProjectID?.rawValue.uuidString ?? ""]
        return left.lexicographicallyPrecedes(right)
    }
}

private func idOrder(_ lhs: ArtifactID, _ rhs: ArtifactID) -> Bool {
    lhs.rawValue.uuidString < rhs.rawValue.uuidString
}
