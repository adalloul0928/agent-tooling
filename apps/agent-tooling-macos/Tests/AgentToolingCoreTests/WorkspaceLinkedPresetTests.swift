import Foundation
import Testing

@testable import AgentToolingCore

/// A linked preset owns only what it contributed. Letting go of a member never
/// removes a manual assignment or one another preset also requires.
@Suite("Workspace linked presets")
struct WorkspaceLinkedPresetTests {
    @Test func addedMembersBecomeThisPresetsOwnContributions() throws {
        let document = try Self.document(members: [Self.alpha, Self.beta], assignments: [])
        let subscription = LinkedPresetSubscription(presetID: Self.presetID, appliedRevision: 1,
                                                    destinations: [Self.codex])

        let update = try #require(WorkspaceLinkedPresetResolver.pendingUpdate(for: subscription, in: document))

        #expect(update.hasPendingChanges)
        #expect(update.changes.allSatisfy { $0.kind == .add })
        #expect(Set(update.changes.map(\.artifactID)) == [Self.alpha, Self.beta])

        var applied = document
        let affected = WorkspaceLinkedPresetResolver.apply(update, to: &applied)
        #expect(Set(affected) == [Self.alpha, Self.beta])
        #expect(applied.assignments.allSatisfy { $0.reason == .preset(presetID: Self.presetID) })
        // Catching up twice changes nothing more.
        let settled = try #require(WorkspaceLinkedPresetResolver.pendingUpdate(for: subscription, in: applied))
        #expect(!settled.hasPendingChanges)
    }

    @Test func aRemovedMemberTakesOnlyThisPresetsContribution() throws {
        let manual = Self.assignment(Self.alpha, reason: .manual, suffix: "1")
        let mine = Self.assignment(Self.alpha, reason: .preset(presetID: Self.presetID), suffix: "2")
        var document = try Self.document(members: [], assignments: [manual, mine])
        let subscription = LinkedPresetSubscription(presetID: Self.presetID, appliedRevision: 1,
                                                    destinations: [Self.codex])

        let update = try #require(WorkspaceLinkedPresetResolver.pendingUpdate(for: subscription, in: document))

        // The destination is kept by something else, so letting go changes
        // nothing there — and that is reported rather than hidden.
        #expect(update.changes.map(\.kind) == [.retainedByOtherReason])
        #expect(update.changes.first?.remainingReasons == [.manual])
        #expect(!update.hasPendingChanges)

        _ = WorkspaceLinkedPresetResolver.apply(update, to: &document)
        #expect(document.assignments.map(\.reason) == [.manual])
    }

    @Test func anotherPresetsRequirementAlsoSurvives() throws {
        let otherPresetID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000d4")!)
        let mine = Self.assignment(Self.alpha, reason: .preset(presetID: Self.presetID), suffix: "1")
        let theirs = Self.assignment(Self.alpha, reason: .preset(presetID: otherPresetID), suffix: "2")
        var document = try Self.document(members: [], assignments: [mine, theirs],
                                         extraPresets: [.init(id: otherPresetID, name: "Other", revision: 1,
                                                              memberArtifactIDs: [Self.alpha])])
        let update = try #require(WorkspaceLinkedPresetResolver.pendingUpdate(
            for: .init(presetID: Self.presetID, appliedRevision: 1, destinations: [Self.codex]),
            in: document))

        _ = WorkspaceLinkedPresetResolver.apply(update, to: &document)

        #expect(document.assignments.map(\.reason) == [.preset(presetID: otherPresetID)])
    }

    @Test func aMemberWithNoOtherReasonIsReleasedCleanly() throws {
        let mine = Self.assignment(Self.alpha, reason: .preset(presetID: Self.presetID), suffix: "1")
        var document = try Self.document(members: [], assignments: [mine])
        let update = try #require(WorkspaceLinkedPresetResolver.pendingUpdate(
            for: .init(presetID: Self.presetID, appliedRevision: 1, destinations: [Self.codex]),
            in: document))

        #expect(update.changes.map(\.kind) == [.removeContribution])
        #expect(update.hasPendingChanges)
        _ = WorkspaceLinkedPresetResolver.apply(update, to: &document)
        #expect(document.assignments.isEmpty)
    }

    @Test func aSubscriptionOnlyTouchesTheDestinationsItWasGiven() throws {
        let elsewhere = PortableDestination(surface: .claudeCode, scope: .user)
        let document = try Self.document(members: [Self.alpha], assignments: [])
        let update = try #require(WorkspaceLinkedPresetResolver.pendingUpdate(
            for: .init(presetID: Self.presetID, appliedRevision: 1, destinations: [Self.codex]),
            in: document))

        #expect(update.changes.allSatisfy { $0.destination == Self.codex })
        #expect(!update.changes.contains { $0.destination == elsewhere })
    }

    @Test func aMissingPresetHasNothingToFollow() throws {
        let document = try Self.document(members: [Self.alpha], assignments: [])
        #expect(WorkspaceLinkedPresetResolver.pendingUpdate(
            for: .init(presetID: ArtifactID(), appliedRevision: 1, destinations: [Self.codex]),
            in: document) == nil)
    }

    private static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
    private static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
    private static let presetID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)
    private static let codex = PortableDestination(surface: .codexCLI, scope: .user)

    private static func assignment(
        _ artifactID: ArtifactID, reason: AssignmentReason, suffix: String
    ) -> AssignmentContribution {
        .init(id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-00000000000" + suffix)!),
              artifactID: artifactID, destination: codex, reason: reason)
    }

    private static func document(
        members: [ArtifactID],
        assignments: [AssignmentContribution],
        extraPresets: [PresetRecord] = []
    ) throws -> PortableWorkspaceDocument {
        var artifacts: [ArtifactRecord] = [alpha, beta].map {
            .init(identity: .init(id: $0, kind: .skill, displayName: $0 == alpha ? "Alpha" : "Beta"),
                  authority: .trackedOnly)
        }
        artifacts.append(.init(identity: .init(id: presetID, kind: .preset, displayName: "Starter"),
                               authority: .centralPersonal))
        artifacts += extraPresets.map {
            .init(identity: .init(id: $0.id, kind: .preset, displayName: $0.name), authority: .centralPersonal)
        }
        return try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!),
            revision: .init(writerID: WorkspaceObjectID()),
            artifacts: artifacts, assignments: assignments,
            presets: [.init(id: presetID, name: "Starter", revision: 2, memberArtifactIDs: members)]
                + extraPresets))
    }
}
