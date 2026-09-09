import Foundation
import Testing

@testable import AgentToolingCore

/// A committed declaration read back against what this workspace holds. This is
/// what makes the file worth committing: somebody checks the project out
/// elsewhere and finds out what they are missing.
@Suite("Workspace project reconciliation")
struct WorkspaceProjectReconciliationTests {
    @Test func somethingHeldAtTheExactPinnedRevisionMatches() throws {
        let result = try Self.reconcile(
            declared: [Self.entry("reviewer")],
            locked: [Self.lockEntry("reviewer", Self.commitA)],
            document: try Self.document(holding: [("reviewer", Self.commitA)]))

        #expect(result.items.map(\.state) == [.matchesLock])
        #expect(result.isFullySatisfied)
        #expect(result.items.first?.heldRevision == Self.commitA)
    }

    @Test func somethingHeldAtADifferentRevisionSaysSoRatherThanCountingAsHeld() throws {
        let result = try Self.reconcile(
            declared: [Self.entry("reviewer")],
            locked: [Self.lockEntry("reviewer", Self.commitA)],
            document: try Self.document(holding: [("reviewer", Self.commitB)]))

        // The project asked for one set of bytes and this workspace has another.
        // "Present" would be the wrong answer.
        #expect(result.items.map(\.state) == [.differsFromLock])
        #expect(result.differingCount == 1)
        #expect(!result.isFullySatisfied)
        #expect(result.items.first?.lockedRevision == Self.commitA)
        #expect(result.items.first?.heldRevision == Self.commitB)
    }

    @Test func somethingTheProjectAsksForAndYouDoNotHaveIsNamed() throws {
        let result = try Self.reconcile(
            declared: [Self.entry("reviewer"), Self.entry("auditor")],
            locked: [Self.lockEntry("reviewer", Self.commitA)],
            document: try Self.document(holding: [("reviewer", Self.commitA)]))

        let missing = try #require(result.items.first { $0.state == .missing })
        #expect(missing.name == "auditor")
        #expect(missing.artifactID == nil)
        #expect(result.missingCount == 1)
    }

    @Test func somethingWithNothingPinnedCannotBeCalledSatisfied() throws {
        let result = try Self.reconcile(
            declared: [Self.entry("reviewer")],
            locked: [],
            document: try Self.document(holding: [("reviewer", Self.commitA)]))

        // "We cannot tell" is not the same answer as "yes".
        #expect(result.items.map(\.state) == [.heldUnpinned])
        #expect(!result.isFullySatisfied)
    }

    @Test func aWorkspaceHoldingItWithNoRevisionOfItsOwnStillDiffersFromAPin() throws {
        let result = try Self.reconcile(
            declared: [Self.entry("reviewer")],
            locked: [Self.lockEntry("reviewer", Self.commitA)],
            document: try Self.document(holding: [("reviewer", nil)]))

        #expect(result.items.map(\.state) == [.differsFromLock])
        #expect(result.items.first?.heldRevision == nil)
    }

    @Test func theSameNameForADifferentKindIsADifferentThing() throws {
        let result = try Self.reconcile(
            declared: [.init(name: "reviewer", kind: .mcpServer)],
            locked: [],
            document: try Self.document(holding: [("reviewer", nil)]))

        // A skill called reviewer does not satisfy a connection called reviewer.
        #expect(result.items.map(\.state) == [.missing])
    }

    @Test func anEmptyDeclarationIsNotQuietlyCalledSatisfied() throws {
        let result = try Self.reconcile(declared: [], locked: [],
                                        document: try Self.document(holding: []))

        #expect(result.items.isEmpty)
        #expect(!result.isFullySatisfied)
    }

    private static let commitA = String(repeating: "a", count: 40)
    private static let commitB = String(repeating: "b", count: 40)

    private static func entry(_ name: String) -> WorkspaceProjectDeclaration.Entry {
        .init(name: name, kind: .skill, repositoryURL: "https://github.com/you/skills",
              requestedRef: "main", packageRelativePath: "skills/\(name)")
    }

    private static func lockEntry(_ name: String, _ commit: String) -> WorkspaceProjectLock.Entry {
        .init(name: name, kind: .skill, repositoryURL: "https://github.com/you/skills",
              requestedRef: "main", revision: .init(kind: .gitCommitSHA1, value: commit),
              contentDigest: .init(value: String(repeating: "c", count: 64)),
              packageRelativePath: "skills/\(name)")
    }

    private static func reconcile(
        declared: [WorkspaceProjectDeclaration.Entry],
        locked: [WorkspaceProjectLock.Entry],
        document: PortableWorkspaceDocument
    ) throws -> WorkspaceProjectDeclarationReconciliation.Result {
        WorkspaceProjectDeclarationReconciliation.reconcile(
            declaration: try .init(entries: declared),
            lock: locked.isEmpty ? nil : try .init(entries: locked),
            against: document)
    }

    /// A workspace holding named skills, each optionally tracking a commit.
    private static func document(holding items: [(String, String?)]) throws -> PortableWorkspaceDocument {
        var artifacts: [ArtifactRecord] = []
        var sources: [PortableSourceDescriptor] = []
        var subscriptions: [UpstreamSubscription] = []
        for (index, item) in items.enumerated() {
            let artifactID = ArtifactID()
            guard let commit = item.1 else {
                artifacts.append(.init(
                    identity: .init(id: artifactID, kind: .skill, displayName: item.0.capitalized),
                    authority: .centralPersonal, declaredName: item.0,
                    contentDigest: .init(value: String(repeating: "d", count: 64))))
                continue
            }
            let sourceID = WorkspaceObjectID()
            let subscriptionID = WorkspaceObjectID()
            sources.append(.init(id: sourceID, role: .publisherRepository,
                                 repositoryURL: "https://github.com/you/skills",
                                 requestedRef: "main", packageRelativePaths: ["skills/\(item.0)"]))
            subscriptions.append(.init(
                id: subscriptionID, artifactID: artifactID, sourceID: sourceID,
                lock: .init(publisherID: "github:you", sourceRootID: sourceID, requestedRef: "main",
                            approvedRevision: .init(kind: .gitCommitSHA1, value: commit),
                            approvedContent: .init(value: String(repeating: "c", count: 64)),
                            packageRelativePath: "skills/\(item.0)")))
            artifacts.append(.init(
                identity: .init(id: artifactID, kind: .skill, displayName: item.0.capitalized),
                authority: .centralUpstream(subscriptionID: subscriptionID), declaredName: item.0,
                contentDigest: .init(value: String(repeating: "c", count: 64))))
            _ = index
        }
        return try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID()),
            artifacts: artifacts, sources: sources, subscriptions: subscriptions))
    }
}
