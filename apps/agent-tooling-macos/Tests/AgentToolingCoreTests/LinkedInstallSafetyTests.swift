import Foundation
import Testing

@testable import AgentToolingCore

final class LinkedDestinationMutationFileManager: FileManager, @unchecked Sendable {
    enum Moment: Equatable, Sendable { case staging, rollback }
    let destination: URL
    let moment: Moment

    init(destination: URL, moment: Moment) {
        self.destination = destination
        self.moment = moment
        super.init()
    }

    override func copyItem(at source: URL, to target: URL) throws {
        try super.copyItem(at: source, to: target)
        let isStaging = target.lastPathComponent.hasPrefix(".agent-tooling-directory-")
        let isRollback = target.pathComponents.contains("rollback")
        if (moment == .staging && isStaging) || (moment == .rollback && isRollback) {
            try Data("local edit during copy".utf8).write(to: destination.appending(path: "SKILL.md"), options: .atomic)
        }
    }
}

struct LinkedInstallSafetyTests {
    @Test func legacyCodexSkillLocationRequiresAnExplicitMatchingBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let withoutBaseline = try fixture.plan(baseline: nil)
        let denied = await OperationEngine(store: fixture.store, homeURL: fixture.home).execute(withoutBaseline)
        #expect(denied.results.first?.status == .failed)
        #expect(try fixture.contents() == "baseline")

        let linked = try fixture.plan(baseline: DirectoryFingerprint.sha256(of: fixture.destination))
        let accepted = await OperationEngine(store: fixture.store, homeURL: fixture.home).execute(linked)
        #expect(accepted.results.first?.status == .succeeded)
        #expect(try fixture.contents() == "upstream")
    }

    @Test(arguments: ["", "not-a-fingerprint", String(repeating: "0", count: 64)])
    func malformedOrWrongBaselineDoesNotAuthorizeLegacyCodexWrites(baseline: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let plan = try fixture.plan(baseline: baseline)
        let review = OperationPlanSafetyReviewer(authority: .init(), managedRoots: []).review(plan)
        #expect(review.hasBlockedSteps)
        let receipt = await OperationEngine(store: fixture.store, homeURL: fixture.home).execute(plan)
        #expect(receipt.results.first?.status == .failed)
        #expect(try fixture.contents() == "baseline")
    }

    @Test func aRemovedLinkedDestinationIsNotRecreatedAsAnUnownedInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let plan = try fixture.plan(baseline: DirectoryFingerprint.sha256(of: fixture.destination))
        try FileManager.default.removeItem(at: fixture.destination)
        let review = OperationPlanSafetyReviewer(authority: .init(), managedRoots: []).review(plan)
        #expect(review.hasBlockedSteps)
        let receipt = await OperationEngine(store: fixture.store, homeURL: fixture.home).execute(plan)
        #expect(receipt.results.first?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test(arguments: [LinkedDestinationMutationFileManager.Moment.staging, .rollback])
    func destinationChangesDuringStagingOrRollbackAreCaughtBeforeSwap(moment: LinkedDestinationMutationFileManager.Moment) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let baseline = try DirectoryFingerprint.sha256(of: fixture.destination)
        try ManagedInstallLedger(records: [
            .init(destinationPath: fixture.destination.path, sourcePath: fixture.source.path,
                  reviewedFingerprint: baseline, reviewedAt: .now)
        ]).save(to: fixture.store)
        let plan = try fixture.plan(baseline: baseline)
        let fileManager = LinkedDestinationMutationFileManager(destination: fixture.destination, moment: moment)
        let receipt = await OperationEngine(store: fixture.store, fileManager: fileManager, homeURL: fixture.home).execute(plan)

        #expect(receipt.results.first?.status == .failed)
        #expect(try fixture.contents() == "local edit during copy")
        #expect(ManagedInstallLedger.load(from: fixture.store).record(forDestination: fixture.destination.path)?.reviewedFingerprint == baseline)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)
        #expect(!remaining.contains { $0.hasPrefix(".agent-tooling-directory-") })
    }

    @Test func matchingBaselineDoesNotAuthorizeNeighboringCodexPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let neighboring = fixture.home.appending(path: ".codex/plugins/example", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: neighboring, withIntermediateDirectories: true)
        try Data("plugin files".utf8).write(to: neighboring.appending(path: "SKILL.md"))
        var plan = try fixture.plan(baseline: DirectoryFingerprint.sha256(of: neighboring))
        plan.steps[0].destinationPath = neighboring.path
        let receipt = await OperationEngine(store: fixture.store, homeURL: fixture.home).execute(plan)
        #expect(receipt.results.first?.status == .failed)
        #expect(try String(contentsOf: neighboring.appending(path: "SKILL.md"), encoding: .utf8) == "plugin files")
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let home: URL
        let source: URL
        let destination: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "linked-install-safety-\(UUID().uuidString)")
            store = try WorkspaceStore(rootURL: root.appending(path: "workspace"))
            home = root.appending(path: "home", directoryHint: .isDirectory)
            source = store.libraryURL.appending(path: "packages/example/skills/example", directoryHint: .isDirectory)
            destination = home.appending(path: ".codex/skills/example", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("upstream".utf8).write(to: source.appending(path: "SKILL.md"))
            try Data("baseline".utf8).write(to: destination.appending(path: "SKILL.md"))
        }

        func plan(baseline: String?) throws -> OperationPlan {
            OperationPlan(
                kind: .installSkill, title: "Update linked skill", summary: "Reviewed upstream update",
                targetSurfaces: [.codexCLI], scope: .user,
                steps: [.init(
                    kind: .copyDirectory, title: "Update example", detail: "Replace the matching linked installation",
                    sourcePath: source.path, sourceFingerprint: try DirectoryFingerprint.sha256(of: source),
                    destinationPath: destination.path, destinationFingerprint: baseline
                )]
            )
        }

        func contents() throws -> String { try String(contentsOf: destination.appending(path: "SKILL.md"), encoding: .utf8) }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
