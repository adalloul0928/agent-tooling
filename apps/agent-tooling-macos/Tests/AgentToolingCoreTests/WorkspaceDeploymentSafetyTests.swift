import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceDeploymentSafetyTests {
    @Test(arguments: [true, false])
    func removalPreservesEditsBeforeAndAfterStaging(editBeforeStaging: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        try await fixture.install()
        let action = WorkspaceDeploymentAction.removeContent(installed: fixture.tree.digest)
        if editBeforeStaging { try fixture.editInstalledSkill() }
        let operation = try fixture.operation(action)
        let step = try #require(operation.steps.first)
        #expect(step.reviewedDestinationDigest == fixture.tree.digest)
        #expect(step.destinationFingerprint == nil, "The review must not grant ownership through a freshly captured fingerprint")
        if !editBeforeStaging { try fixture.editInstalledSkill() }

        let receipt = await fixture.executor().execute(operation)

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("changed after review") == true)
        #expect(try String(contentsOf: fixture.installedSkill, encoding: .utf8) == Fixture.localEdit)
        #expect(try fixture.store.managedInstallLedger().record(forDestination: fixture.destination.path) != nil)
    }

    @Test(arguments: [true, false])
    func updatePreservesEditsBeforeAndAfterStaging(editBeforeStaging: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        try await fixture.install()
        let replacement = try Fixture.content("Reviewed update")
        let action = WorkspaceDeploymentAction.updateContent(from: fixture.tree.digest, to: replacement.digest)
        if editBeforeStaging { try fixture.editInstalledSkill() }
        let operation = try fixture.operation(action, content: replacement)
        #expect(operation.steps.first?.reviewedDestinationDigest == fixture.tree.digest)
        if !editBeforeStaging { try fixture.editInstalledSkill() }

        let receipt = await fixture.executor().execute(operation)

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("changed after review") == true)
        #expect(try String(contentsOf: fixture.installedSkill, encoding: .utf8) == Fixture.localEdit)
    }

    @Test(arguments: [true, false])
    func matchingReviewedContentDoesNotGrantOwnership(removing: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        try WorkspacePackageExporter.write(tree: fixture.tree, to: fixture.destination)
        let replacement = try Fixture.content("Replacement")
        let action: WorkspaceDeploymentAction =
            removing
            ? .removeContent(installed: fixture.tree.digest)
            : .updateContent(from: fixture.tree.digest, to: replacement.digest)
        let operation = try fixture.operation(action, content: replacement)

        let receipt = await fixture.executor().execute(operation)

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("cannot prove it installed") == true)
        #expect(try await PackageTreeCapture().capture(directory: fixture.destination) == fixture.tree)
    }

    @Test(arguments: [true, false])
    func editsDuringFilesystemPreparationAreRecheckedBeforeMutation(removing: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        try await fixture.install()
        let replacement = try Fixture.content("Replacement")
        let action: WorkspaceDeploymentAction =
            removing
            ? .removeContent(installed: fixture.tree.digest)
            : .updateContent(from: fixture.tree.digest, to: replacement.digest)
        let operation = try fixture.operation(action, content: replacement)
        let manager = DestinationMutationFileManager(destination: fixture.installedSkill, removing: removing)
        let executor = OperationExecutor(store: fixture.store, fileManager: manager, homeURL: fixture.home.url)

        let receipt = await executor.execute(operation)

        #expect(receipt.results.first?.status == .failed)
        #expect(receipt.results.first?.output.contains("changed after review") == true)
        #expect(try String(contentsOf: fixture.installedSkill, encoding: .utf8) == Fixture.localEdit)
    }

    @Test func removalKeepsTheWholeTreeAndItsPersistedReceiptCanRestoreIt() async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        try await fixture.install()
        let operation = try fixture.operation(.removeContent(installed: fixture.tree.digest))

        let receipt = await fixture.executor().execute(operation)

        #expect(receipt.results.first?.status == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try fixture.store.managedInstallLedger().record(forDestination: fixture.destination.path) == nil)
        let reopened = try WorkspaceRevisionStore(
            containerRoot: fixture.home.root.appending(path: "workspace"),
            workspaceID: fixture.store.workspaceID, deviceID: fixture.store.deviceID)
        let saved = try #require(try reopened.operationReceipts().first { $0.id == receipt.id })
        let output = try #require(saved.results.first?.output)
        let beginning = try #require(output.range(of: "Recovery folder: ")?.upperBound)
        let ending = try #require(output.range(of: ". To restore it,", range: beginning..<output.endIndex)?.lowerBound)
        let recovery = URL(fileURLWithPath: String(output[beginning..<ending]))
        #expect(output.contains("when the destination is empty"))
        #expect(PathContainment.containsResolved(recovery, in: reopened.receiptsURL.appending(path: "rollback")))
        #expect(try await PackageTreeCapture().capture(directory: recovery) == fixture.tree)

        try FileManager.default.moveItem(at: recovery, to: fixture.destination)

        #expect(try await PackageTreeCapture().capture(directory: fixture.destination) == fixture.tree)
    }

    @Test func aReviewedUpdateStillReplacesAnUnchangedManagedCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        try await fixture.install()
        let replacement = try Fixture.content("Updated")
        let operation = try fixture.operation(.updateContent(from: fixture.tree.digest, to: replacement.digest), content: replacement)

        let receipt = await fixture.executor().execute(operation)

        #expect(receipt.results.first?.status == .succeeded, "\(receipt.results.map(\.output))")
        #expect(try await PackageTreeCapture().capture(directory: fixture.destination) == replacement)
    }

    @Test func theReviewedDigestSurvivesSerializationAndDistinguishesPlans() throws {
        let fixture = try Fixture()
        defer { fixture.home.remove() }
        let plan = try fixture.operation(.removeContent(installed: fixture.tree.digest))
        let encoded = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(OperationPlan.self, from: encoded) == plan)
        var changed = plan
        changed.steps[0].reviewedDestinationDigest = try Fixture.content("Different review").digest
        #expect(Set([plan, changed]).count == 2)
        #expect(try JSONEncoder().encode(changed) != encoded)

        var legacyStep = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan.steps[0])) as? [String: Any])
        legacyStep.removeValue(forKey: "reviewedDestinationDigest")
        let legacy = try JSONDecoder().decode(OperationStep.self, from: JSONSerialization.data(withJSONObject: legacyStep))
        #expect(legacy.reviewedDestinationDigest == nil)
    }

    private final class DestinationMutationFileManager: FileManager, @unchecked Sendable {
        let destination: URL
        let removing: Bool

        init(destination: URL, removing: Bool) {
            self.destination = destination
            self.removing = removing
            super.init()
        }

        override func copyItem(at source: URL, to target: URL) throws {
            try super.copyItem(at: source, to: target)
            if !removing, target.lastPathComponent.hasPrefix(".agent-tooling-directory-") { try mutate() }
        }

        override func createDirectory(
            at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil
        )
            throws
        {
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
            if removing, url.pathComponents.contains("rollback") { try mutate() }
        }

        private func mutate() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.deletingLastPathComponent().path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try Data(Fixture.localEdit.utf8).write(to: destination)
        }
    }

    private struct Fixture {
        static let localEdit = "---\nname: fixture-skill\ndescription: Local edit\n---\nKeep this work.\n"
        let home: FixtureHome
        let store: WorkspaceRevisionStore
        let tree: CapturedPackageTree
        let artifact: ArtifactRecord
        let physicalID = WorkspaceObjectID()

        var destination: URL { home.appending(".agents/skills/fixture-skill") }
        var installedSkill: URL { destination.appending(path: "SKILL.md") }

        init() throws {
            home = try FixtureHome("deployment-safety")
            tree = try Self.content("Original")
            artifact = .init(
                identity: .init(kind: .skill, displayName: "Fixture skill"),
                authority: .centralPersonal, declaredName: "fixture-skill", contentDigest: tree.digest)
            let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: home.root.appending(path: "workspace"), workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            try store.prepareManagedDirectories()
        }

        static func content(_ description: String) throws -> CapturedPackageTree {
            try CapturedPackageTree(entries: [
                .init(
                    relativePath: "SKILL.md",
                    kind: .file(bytes: Data("---\nname: fixture-skill\ndescription: \(description)\n---\n".utf8), executable: false)),
                .init(relativePath: "empty", kind: .directory),
                .init(relativePath: "tools", kind: .directory),
                .init(relativePath: "tools/check.sh", kind: .file(bytes: Data("#!/bin/sh\nexit 0\n".utf8), executable: true)),
            ])
        }

        func operation(_ action: WorkspaceDeploymentAction, content: CapturedPackageTree? = nil) throws -> OperationPlan {
            let plan = WorkspaceDeploymentPlan(
                items: [
                    .init(
                        artifactID: artifact.identity.id, displayName: "Fixture skill", physicalDestinationID: physicalID,
                        surface: .codexCLI, scope: .user, logicalProjectID: nil, action: action, desiredEnabled: nil, reasons: [.manual])
                ], exclusions: [])
            let staged = try WorkspaceDeploymentOperations.stage(
                plan, artifacts: [artifact], content: [(content ?? tree).digest: content ?? tree],
                stagingRoot: store.libraryURL.appending(path: "staged-deployments"), homeURL: home.url)
            return try #require(WorkspaceDeploymentOperations.operations(for: staged).first)
        }

        func executor() -> OperationExecutor { OperationExecutor(store: store, homeURL: home.url) }

        func install() async throws {
            let receipt = await executor().execute(try operation(.installContent(digest: tree.digest)))
            try #require(receipt.results.first?.status == .succeeded, "\(receipt.results.map(\.output))")
        }

        func editInstalledSkill() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installedSkill.path)
            try write(installedSkill, Self.localEdit)
        }
    }
}
