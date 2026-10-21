import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// Whether the launch finds a workspace on this Mac, as `recordState` reads
/// the support folder: no record is a first run, a record is an open, and a
/// record this build cannot read is still a workspace, so the launch never
/// starts a second one beside it.
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
        #expect(WorkspaceLaunch.recordState(supportRoot: root) == .none)
    }

    @Test func aRecordWrittenThroughTheLocatorIsAWorkspace() throws {
        let root = Self.scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = try WorkspaceLocator(root: root)
        try locator.write(.init(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID()))
        #expect(WorkspaceLaunch.recordState(supportRoot: root) != .none)
    }

    @Test func aRecordThisBuildCannotReadIsTreatedAsPresent() throws {
        let root = Self.scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json at all".utf8)
            .write(to: root.appending(path: WorkspaceLocator.recordFileName))
        #expect(WorkspaceLaunch.recordState(supportRoot: root) != .none)
    }
}
