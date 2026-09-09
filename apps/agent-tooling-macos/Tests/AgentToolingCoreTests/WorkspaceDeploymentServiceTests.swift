import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

/// The service plans only against content this workspace can actually read, and
/// assumes nothing is already installed.
@Suite("Workspace deployment service")
struct WorkspaceDeploymentServiceTests {
    @Test func onlyContentTheStoreCanReadBecomesAPlannedInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // Recorded in the document, but never published to the content store.
        let missing = try await fixture.service.deploymentPlan(targets: [fixture.target])
        #expect(missing.items.isEmpty)
        #expect(missing.exclusions.map(\.reason) == [.missingContent])

        _ = try await fixture.contentStore.store(fixture.tree)
        let planned = try await fixture.service.deploymentPlan(targets: [fixture.target])

        #expect(planned.exclusions.isEmpty, "\(planned.exclusions)")
        #expect(planned.items.map(\.artifactID) == [fixture.artifactID])
        #expect(planned.items.first?.action == .installContent(digest: fixture.tree.digest))
        #expect(planned.items.first?.surface == .codexCLI)
    }

    @Test func planningReadsCommittedStateAndChangesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.contentStore.store(fixture.tree)
        let before = try #require(try fixture.store.snapshot())

        _ = try await fixture.service.deploymentPlan(targets: [fixture.target])
        _ = try await fixture.service.deploymentPlan(targets: [fixture.target])

        let after = try #require(try fixture.store.snapshot())
        #expect(after.document.revision.id == before.document.revision.id)
        #expect(after.document.assignments == before.document.assignments)
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let contentStore: CentralPackageContentStore
        let service: WorkspaceApplicationService
        let artifactID = ArtifactID()
        let tree: CapturedPackageTree
        let target: ResolvedAssignmentTarget

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "workspace-deployment-service-\(UUID())")
            let contentURL = root.appending(path: "content")
            try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            tree = try CapturedPackageTree(entries: [
                .init(relativePath: "SKILL.md", kind: .file(
                    bytes: Data("---\nname: personal\ndescription: Fixture\n---\n\n# Personal\n".utf8),
                    executable: false)),
            ])
            let writerID = WorkspaceObjectID()
            let destination = WorkspaceObjectID()
            target = .init(selector: .init(surface: .codexCLI, scope: .user, logicalProjectID: nil),
                           physicalDestinationID: destination, installedClientVersion: "1.0.0",
                           adapterContractVersion: 1,
                           componentContexts: [.init(component: .skill, transport: nil)])
            let artifact = ArtifactRecord(
                identity: .init(id: artifactID, kind: .skill, displayName: "Personal"),
                authority: .centralPersonal, declaredName: "personal", contentDigest: tree.digest)
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [artifact],
                assignments: [.init(artifactID: artifactID,
                                    destination: .init(surface: .codexCLI, scope: .user),
                                    reason: .manual)]))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            device.capabilityEvidence = [
                .init(surface: .codexCLI, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                      component: .skill, scopes: [.user], support: .supported,
                      observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ]
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID,
                                               deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            contentStore = try CentralPackageContentStore(directory: contentURL)
            service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: contentStore)
        }

        func remove() {
            func unlock(_ url: URL) {
                var value = stat()
                guard lstat(url.path, &value) == 0 else { return }
                _ = chmod(url.path, 0o700)
                guard value.st_mode & S_IFMT == S_IFDIR else { return }
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                    unlock(child)
                }
            }
            unlock(root)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
