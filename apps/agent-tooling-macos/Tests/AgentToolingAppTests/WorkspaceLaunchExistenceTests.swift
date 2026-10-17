import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// `hasWorkspace` decides whether a first launch offers the choice between
/// starting here and joining another Mac. Its three cases are: no record is a
/// first run (false), a record is an open (true), and a record this build
/// cannot read is treated as present (true) so a second workspace is never
/// started beside one that already exists.
@Suite("Workspace launch · does this Mac have a workspace")
@MainActor
struct WorkspaceLaunchExistenceTests {
    /// A scratch support folder each test owns, removed afterwards.
    private static func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "workspace-existence-\(UUID())", directoryHint: .isDirectory)
    }

    @Test func anEmptyFolderIsAFirstRun() throws {
        let root = Self.scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkspaceLaunch.hasWorkspace(supportRoot: root) == false)
    }

    @Test func aRecordWrittenThroughTheLocatorIsAWorkspace() throws {
        let root = Self.scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = try WorkspaceLocator(root: root)
        try locator.write(.init(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID()))
        #expect(WorkspaceLaunch.hasWorkspace(supportRoot: root) == true)
    }

    @Test func aRecordThisBuildCannotReadIsTreatedAsPresent() throws {
        let root = Self.scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json at all".utf8)
            .write(to: root.appending(path: WorkspaceLocator.recordFileName))
        #expect(WorkspaceLaunch.hasWorkspace(supportRoot: root) == true)
    }
}
