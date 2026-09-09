import Foundation
import Testing

@testable import AgentToolingCore

/// Staging the exact reviewed bytes and handing them to the existing operation
/// path. Nothing here installs anything.
@Suite("Workspace deployment operations")
struct WorkspaceDeploymentOperationsTests {
    @Test func stagedContentMatchesTheApprovedRevisionAndRoutesToItsClientFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let staged = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home)

        #expect(staged.count == 1)
        let deployment = try #require(staged.first)
        #expect(deployment.deploymentName == "personal")
        #expect(deployment.destinationPath == fixture.home.appending(path: ".agents/skills/personal").path)
        // The staged folder is the approved tree, byte for byte.
        #expect(try Data(contentsOf: URL(fileURLWithPath: deployment.stagingPath)
            .appending(path: "SKILL.md")) == fixture.skillBytes)
        #expect(deployment.fingerprint
            == (try DirectoryFingerprint.sha256(of: URL(fileURLWithPath: deployment.stagingPath))))
        // Staging touches nothing in the client's own folder.
        #expect(!FileManager.default.fileExists(atPath: deployment.destinationPath))
    }

    @Test func oneReviewableOperationPerDestinationCarriesItsOwnFingerprint() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home)

        let operations = WorkspaceDeploymentOperations.operations(for: staged)

        #expect(operations.count == 1)
        let plan = try #require(operations.first)
        #expect(plan.kind == .installSkill)
        #expect(plan.targetSurfaces == [.codexCLI])
        #expect(plan.requiresConfirmation)
        let step = try #require(plan.steps.first)
        #expect(step.kind == .copyDirectory)
        #expect(step.sourceFingerprint == staged.first?.fingerprint)
        #expect(step.destinationPath == staged.first?.destinationPath)
    }

    @Test func aNativePackageOrConnectionIsNotStagedAsAFolderCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let route = NativePackageRoute(client: .codex, externalPluginID: "browser")
        let plan = WorkspaceDeploymentPlan(items: [
            .init(artifactID: fixture.artifact.identity.id, displayName: "Browser",
                  physicalDestinationID: WorkspaceObjectID(), surface: .codexCLI, scope: .user,
                  logicalProjectID: nil, action: .installNativePackage(route: route),
                  desiredEnabled: nil, reasons: [.manual]),
        ], exclusions: [])

        let staged = try WorkspaceDeploymentOperations.stage(
            plan, artifacts: [fixture.artifact], content: [:],
            stagingRoot: fixture.staging, homeURL: fixture.home)

        // Their own command bridges own these, with their own evidence rules.
        #expect(staged.isEmpty)
        #expect(WorkspaceDeploymentOperations.operations(for: staged).isEmpty)
    }

    @Test func contentTheLibraryCannotSupplyIsRefusedRatherThanStagedEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: WorkspaceDeploymentOperationError.missingContent) {
            _ = try WorkspaceDeploymentOperations.stage(
                fixture.plan, artifacts: [fixture.artifact], content: [:],
                stagingRoot: fixture.staging, homeURL: fixture.home)
        }
    }

    @Test func aProjectDeploymentNeedsItsFolderOnThisMac() throws {
        let fixture = try Fixture(scope: .project)
        defer { fixture.remove() }

        #expect(throws: WorkspaceDeploymentOperationError.missingProjectRoot) {
            _ = try WorkspaceDeploymentOperations.stage(
                fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
                stagingRoot: fixture.staging, homeURL: fixture.home)
        }

        let project = fixture.root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let staged = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home,
            projectRoots: [fixture.projectID: project])
        #expect(staged.first?.destinationPath == project.appending(path: ".agents/skills/personal").path)
    }

    @Test func thePlannedOperationActuallyInstallsTheReviewedVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home)
        let operation = try #require(WorkspaceDeploymentOperations.operations(for: staged).first)
        let executor = OperationExecutor(store: fixture.store, homeURL: fixture.home)

        let receipt = await executor.execute(operation)

        #expect(receipt.results.allSatisfy { $0.status == .succeeded }, "\(receipt.results.map(\.output))")
        let installed = URL(fileURLWithPath: try #require(staged.first).destinationPath)
            .appending(path: "SKILL.md")
        #expect(try Data(contentsOf: installed) == fixture.skillBytes)
    }

    @Test func aStagedFolderChangedAfterReviewDoesNotInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home)
        let operation = try #require(WorkspaceDeploymentOperations.operations(for: staged).first)
        let deployment = try #require(staged.first)
        // Something edits the staged copy between review and apply.
        let file = URL(fileURLWithPath: deployment.stagingPath).appending(path: "SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deployment.stagingPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("---\nname: personal\ndescription: Changed\n---\n".utf8).write(to: file)
        let executor = OperationExecutor(store: fixture.store, homeURL: fixture.home)

        let receipt = await executor.execute(operation)

        #expect(receipt.results.contains { $0.status == .failed })
        #expect(!FileManager.default.fileExists(atPath: deployment.destinationPath))
    }

    @Test func onlyWhatThisAppInstalledIsOfferedForRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = try #require(fixture.plan.items.first).physicalDestinationID
        let artifactID = fixture.artifact.identity.id
        let key = WorkspaceDeploymentInstallKey(artifactID: artifactID, physicalDestinationID: destination)
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID()),
            artifacts: [fixture.artifact]))
        var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        device.capabilityEvidence = [
            .init(surface: .codexCLI, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                  component: .skill, scopes: [.user], support: .supported,
                  observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let target = ResolvedAssignmentTarget(
            selector: .init(surface: .codexCLI, scope: .user, logicalProjectID: nil),
            physicalDestinationID: destination, installedClientVersion: "1.0.0",
            adapterContractVersion: 1, componentContexts: [.init(component: .skill, transport: nil)])
        let measured = WorkspaceDeploymentObservation(
            artifactID: artifactID, physicalDestinationID: destination,
            isPresent: true, contentDigest: fixture.tree.digest)

        // Nothing assigned any more, and this app can prove it installed it.
        let withProof = WorkspaceDeploymentPlanner.plan(
            document: document, device: device, targets: [target],
            observations: [measured], provenInstalls: [key])
        #expect(withProof.items.map(\.action) == [.removeContent(installed: fixture.tree.digest)])

        // Without that proof, someone else's copy is left exactly where it is.
        let withoutProof = WorkspaceDeploymentPlanner.plan(
            document: document, device: device, targets: [target], observations: [measured])
        #expect(withoutProof.items.isEmpty)

        // Proof but no measurement is not enough to remove anything.
        let unmeasured = WorkspaceDeploymentPlanner.plan(
            document: document, device: device, targets: [target], provenInstalls: [key])
        #expect(unmeasured.items.isEmpty)
    }

    @Test func aRemovalRefusesAFolderThatNoLongerMatchesWhatWasApproved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Install first, so this app owns the destination.
        let installed = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home)
        let executor = OperationExecutor(store: fixture.store, homeURL: fixture.home)
        _ = await executor.execute(try #require(WorkspaceDeploymentOperations.operations(for: installed).first))
        let destinationPath = try #require(installed.first).destinationPath

        // Someone edits the installed copy.
        let file = URL(fileURLWithPath: destinationPath).appending(path: "SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("---\nname: personal\ndescription: Edited by hand\n---\n".utf8).write(to: file)

        let removal = OperationPlan(kind: .installSkill, title: "Remove", summary: "",
            steps: [.init(id: UUID(), kind: .removeManagedDirectory, title: "Remove personal",
                          detail: "", destinationPath: destinationPath,
                          destinationFingerprint: try #require(installed.first).fingerprint)])
        let receipt = await executor.execute(removal)

        // The edited folder survives; nothing this app did not approve is deleted.
        #expect(receipt.results.allSatisfy { $0.status != .succeeded })
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func reviewedPackageAndConnectionPlansBecomeTheirOwnApprovedOperations() throws {
        let plugin = WorkspaceNativePluginCommandPlan(
            artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(),
            surface: .codexCLI, scope: .user, externalPluginID: "browser",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"), executable: "codex",
            arguments: ["plugin", "install", "browser"])
        let connection = WorkspaceManagedMCPCommandPlan(
            artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(),
            surface: .claudeCode, scope: .user, nativeServerIdentifier: "files",
            executableURL: URL(fileURLWithPath: "/usr/local/bin/claude"), executable: "claude",
            arguments: ["mcp", "add", "files"], workingDirectoryPath: nil)

        let plans = WorkspaceDeploymentOperations.operations(
            nativePlugins: [plugin], managedConnections: [connection])

        #expect(plans.count == 2)
        let installPlan = plans.first { $0.kind == .installPlugin }
        let install = try #require(installPlan)
        #expect(install.targetSurfaces == [.codexCLI])
        #expect(install.requiresConfirmation == true)
        #expect(install.steps.first?.kind == .command)
        #expect(install.steps.first?.arguments == ["plugin", "install", "browser"])
        let configurePlan = plans.first { $0.kind == .configureMCP }
        let configure = try #require(configurePlan)
        #expect(configure.targetSurfaces == [.claudeCode])
        #expect(configure.steps.first?.arguments == ["mcp", "add", "files"])
        // Each app's work stays its own approval, never one mixed batch.
        #expect(Set(plans.flatMap(\.targetSurfaces)).count == 2)
    }

    @Test func nothingReviewedProducesNoCommandOperations() {
        #expect(WorkspaceDeploymentOperations.operations().isEmpty)
    }

    @Test func aDestinationThisMacRedirectedWritesWhereThePersonPointedIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linked = fixture.root.appending(path: "linked")
        var device = DeviceWorkspaceState(workspaceID: WorkspaceObjectID())
        try WorkspaceLinkedDestinations.register(
            selector: .init(surface: .codexCLI, scope: .user), path: linked.path,
            in: &device, managedLibraryRoot: fixture.staging)

        let staged = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home, device: device)

        // Not the client's default folder, and the item keeps its own name
        // inside the folder rather than becoming it.
        let deployment = try #require(staged.first)
        #expect(deployment.destinationPath == linked.appending(path: "personal").path)
        #expect(deployment.destinationPath != fixture.home.appending(path: ".agents/skills/personal").path)
    }

    @Test func anApplyOnceDestinationNeverWritesOverWhatItDidNotPutThere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linked = fixture.root.appending(path: "linked")
        let occupied = linked.appending(path: "personal")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let theirs = occupied.appending(path: "NOTES.md")
        try Data("someone else's work\n".utf8).write(to: theirs)
        var device = DeviceWorkspaceState(workspaceID: WorkspaceObjectID())
        try WorkspaceLinkedDestinations.register(
            selector: .init(surface: .codexCLI, scope: .user), path: linked.path,
            in: &device, managedLibraryRoot: fixture.staging)

        #expect(throws: WorkspaceDeploymentOperationError.destinationOccupied(path: occupied.path)) {
            _ = try WorkspaceDeploymentOperations.stage(
                fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
                stagingRoot: fixture.staging, homeURL: fixture.home, device: device)
        }
        // Exactly as it was, and nothing of ours beside it.
        #expect(try Data(contentsOf: theirs) == Data("someone else's work\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: occupied.appending(path: "SKILL.md").path))
    }

    @Test func aLinkedDestinationThisAppFilledBeforeIsUpdatedRatherThanRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linked = fixture.root.appending(path: "linked")
        let ours = linked.appending(path: "personal")
        try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
        var device = DeviceWorkspaceState(workspaceID: WorkspaceObjectID())
        try WorkspaceLinkedDestinations.register(
            selector: .init(surface: .codexCLI, scope: .user), path: linked.path,
            in: &device, managedLibraryRoot: fixture.staging)

        // The caller's own proof that this app put that folder there.
        let staged = try WorkspaceDeploymentOperations.stage(
            fixture.plan, artifacts: [fixture.artifact], content: [fixture.tree.digest: fixture.tree],
            stagingRoot: fixture.staging, homeURL: fixture.home, device: device,
            provenInstalls: [ours.path])

        #expect(staged.first?.destinationPath == ours.path)
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let staging: URL
        let store: WorkspaceRevisionStore
        let tree: CapturedPackageTree
        let artifact: ArtifactRecord
        let plan: WorkspaceDeploymentPlan
        let projectID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f6")!)
        let skillBytes = Data("---\nname: personal\ndescription: Fixture\n---\n\n# Personal\n".utf8)

        init(scope: ToolingScope = .user) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "deployment-operations-\(UUID())")
            home = root.appending(path: "home")
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "workspace", directoryHint: .isDirectory),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            try store.prepareManagedDirectories()
            // Staging lives inside the app's own managed library, because the
            // executor refuses to copy content from anywhere else.
            staging = store.libraryURL.appending(path: "staged-deployments")
            for url in [home, staging] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            tree = try CapturedPackageTree(entries: [
                .init(relativePath: "SKILL.md", kind: .file(bytes: skillBytes, executable: false)),
            ])
            let artifactID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
            artifact = .init(identity: .init(id: artifactID, kind: .skill, displayName: "Personal"),
                             authority: .centralPersonal, declaredName: "personal", contentDigest: tree.digest)
            plan = .init(items: [
                .init(artifactID: artifactID, displayName: "Personal",
                      physicalDestinationID: WorkspaceObjectID(
                          UUID(uuidString: "00000000-0000-0000-0000-000000000101")!),
                      surface: .codexCLI, scope: scope,
                      logicalProjectID: scope == .project ? projectID : nil,
                      action: .installContent(digest: tree.digest),
                      desiredEnabled: nil, reasons: [.manual]),
            ], exclusions: [])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
