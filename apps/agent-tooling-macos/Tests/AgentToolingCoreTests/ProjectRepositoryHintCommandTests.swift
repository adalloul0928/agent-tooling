import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// A project carries the repositories it is a checkout of, in one spelling,
/// so a second Mac can recognise its own clone as the same project.
@Suite("Project repository hints")
struct ProjectRepositoryHintCommandTests {
    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init() throws {
            root = try TemporaryFolder("project-hints").url
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writerID)))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try .init(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = .init(store: store, writerID: writerID)
        }

        var head: WorkspaceObjectID {
            get throws { try #require(try store.snapshot()).document.revision.id }
        }

        func project(named name: String) throws -> LogicalProjectRecord {
            try #require(try store.snapshot()?.document.logicalProjects.first { $0.name == name })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func creatingFromACheckoutRecordsTheRepositoryOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        _ = try await fixture.service.createProject(
            .init(
                expectedRevisionID: try fixture.head, name: "Order",
                repositoryHints: ["git@github.com:acme/order-history.git", "https://github.com/acme/order-history"]))

        #expect(try fixture.project(named: "Order").repositoryHints == ["https://github.com/acme/order-history"])
    }

    @Test func somethingThatIsNotARepositoryIsRefusedNotDropped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await #expect(throws: WorkspaceDomainValidationError.self) {
            try await fixture.service.createProject(
                .init(
                    expectedRevisionID: try fixture.head, name: "Scratch", repositoryHints: ["/Users/me/src/scratch"]))
        }
        #expect(try fixture.store.snapshot()?.document.logicalProjects.isEmpty == true)
    }

    @Test func addingAHintNormalisesAndNeverDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.createProject(.init(expectedRevisionID: try fixture.head, name: "Web"))
        let web = try fixture.project(named: "Web")
        #expect(web.repositoryHints.isEmpty)

        _ = try await fixture.service.addProjectRepositoryHint(
            .init(
                expectedRevisionID: try fixture.head, projectID: web.id, repository: "ssh://git@github.com/acme/web.git"))
        #expect(try fixture.project(named: "Web").repositoryHints == ["https://github.com/acme/web"])

        // The same repository, spelled another way, changes nothing.
        _ = try await fixture.service.addProjectRepositoryHint(
            .init(
                expectedRevisionID: try fixture.head, projectID: web.id, repository: "https://github.com/acme/web"))
        #expect(try fixture.project(named: "Web").repositoryHints == ["https://github.com/acme/web"])

        // A second repository is a second hint: a monorepo split, a mirror.
        _ = try await fixture.service.addProjectRepositoryHint(
            .init(
                expectedRevisionID: try fixture.head, projectID: web.id, repository: "git@gitlab.com:acme/web.git"))
        #expect(try fixture.project(named: "Web").repositoryHints.count == 2)
    }

    @Test func aHintForAProjectThatIsNotThereIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await #expect(throws: WorkspaceRevisionStoreError.missingArtifact) {
            try await fixture.service.addProjectRepositoryHint(
                .init(
                    expectedRevisionID: try fixture.head, projectID: ArtifactID(), repository: "https://github.com/acme/web"))
        }
    }

    @Test func scanRootsAreADeviceChoiceThatOlderStoresDecodeWithout() throws {
        let decoded = try JSONDecoder().decode(
            DeviceWorkspacePreferences.self,
            from: Data(#"{"automaticallyCheckHealth":true,"enabledClients":[]}"#.utf8))
        #expect(decoded.projectScanRoots == nil)
        let preferences = DeviceWorkspacePreferences(projectScanRoots: ["/Users/me/src"])
        let roundTripped = try JSONDecoder().decode(DeviceWorkspacePreferences.self, from: JSONEncoder().encode(preferences))
        #expect(roundTripped.projectScanRoots == ["/Users/me/src"])
    }
}
