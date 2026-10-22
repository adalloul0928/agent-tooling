import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Workspace launch")
@MainActor
struct WorkspaceLaunchTests {
    /// A fresh container holds only the revision store. The launch has to make
    /// the content store's directory itself, or every skill intake on a real
    /// Mac fails with "cannot reach its stored content".
    @Test func aFreshWorkspaceCanReachItsContentStore() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        #expect(fixture.workspace.contentStore != nil)
        let contentDirectory = fixture.workspace.store.databaseURL
            .deletingLastPathComponent().appending(path: "content")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: contentDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
