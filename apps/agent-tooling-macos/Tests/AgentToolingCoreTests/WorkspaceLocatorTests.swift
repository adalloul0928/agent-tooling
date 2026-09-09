import Foundation
import Testing

@testable import AgentToolingCore

/// Where this Mac's workspace is. One record naming one workspace, replacing
/// the registry that existed to choose between two stores.
@Suite("Workspace locator")
struct WorkspaceLocatorTests {
    @Test func aMacWithNoWorkspaceHasNoneRatherThanFailing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try fixture.locator.read() == nil)
        #expect(try fixture.locator.open() == nil)
    }

    @Test func aRecordedWorkspaceIsFoundAgainAfterReopening() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = WorkspaceLocator.Record(workspaceID: WorkspaceObjectID(),
                                             deviceID: WorkspaceObjectID())

        try fixture.locator.write(record)

        #expect(try WorkspaceLocator(root: fixture.root).read() == record)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.locator.recordURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }

    @Test func aRecordThisBuildCannotReadIsAnErrorNotAnAbsence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data(#"{"formatVersion":99}"#.utf8).write(to: fixture.locator.recordURL)

        // Treating it as absent would start a second workspace beside one that
        // already exists.
        #expect(throws: WorkspaceLocatorError.unsupportedFormat) { _ = try fixture.locator.read() }
    }

    @Test func theRecordNamesIdentifiersAndNoPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.locator.write(.init(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID()))

        // The path comes from the folder it was found in, so moving the folder
        // moves the workspace and no stale path can point somewhere gone.
        let text = String(decoding: try Data(contentsOf: fixture.locator.recordURL), as: UTF8.self)
        #expect(!text.contains("/"))
        #expect(!text.contains(fixture.root.lastPathComponent))
    }

    @Test func afterAFirstRunTheWorkspaceIsFoundByItsOwnRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let created = try await fixture.locator.openOrCreate(
            homeURL: fixture.home, runner: StubRunner(), registry: .init(adapters: []))

        #expect(try created.snapshot() != nil)
        let reopened = try #require(try WorkspaceLocator(root: fixture.root).open())
        #expect(try reopened.snapshot()?.document.workspaceID
            == (try created.snapshot()?.document.workspaceID))
    }

    @Test func openingTwiceReturnsTheSameWorkspaceRatherThanASecond() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.locator.openOrCreate(
            homeURL: fixture.home, runner: StubRunner(), registry: .init(adapters: []))

        let second = try await fixture.locator.openOrCreate(
            homeURL: fixture.home, runner: StubRunner(), registry: .init(adapters: []))

        #expect(try first.snapshot()?.document.workspaceID == (try second.snapshot()?.document.workspaceID))
    }

    @Test func aRootThatHasNotBeenResolvedIsRefused() {
        // A path still carrying `..` has not been decided yet, and two of them
        // can name one folder. Refusing here keeps one workspace to one path.
        #expect(throws: WorkspaceLocatorError.invalidRoot) {
            _ = try WorkspaceLocator(root: URL(fileURLWithPath: "/tmp/somewhere/../elsewhere"))
        }
        #expect(throws: WorkspaceLocatorError.invalidRoot) {
            _ = try WorkspaceLocator(root: URL(string: "https://example.com/workspace")!)
        }
    }

    private struct StubRunner: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            .init(status: 127, standardOutput: "", standardError: "")
        }

        func run(executable: String, arguments: [String], standardInput: Data,
                 currentDirectory: URL?) async throws -> CommandOutput {
            .init(status: 127, standardOutput: "", standardError: "")
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let locator: WorkspaceLocator

        init() throws {
            let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "workspace-locator-\(UUID())")
            root = base.appending(path: "support")
            home = base.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            locator = try WorkspaceLocator(root: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }
}
