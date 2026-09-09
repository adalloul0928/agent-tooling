import AgentToolingCore
import Foundation
import Testing
@testable import AgentToolingApp

struct WorkspacePreviewLaunchTests {
    @Test func ordinaryLaunchDoesNotDiscoverOrSelectAWorkspace() throws {
        #expect(try WorkspacePreviewLaunch.parse(arguments: ["AgentTooling", "--agent-tooling-section", "skills"]) == nil)
    }

    @Test func explicitIDsAndRootAreRequiredTogether() throws {
        let workspace = UUID(), device = UUID()
        let args = ["AgentTooling", "--agent-tooling-versioned-preview-root", "/tmp/disposable-preview",
                    "--agent-tooling-workspace-id", workspace.uuidString, "--agent-tooling-device-id", device.uuidString]
        let launch = try #require(try WorkspacePreviewLaunch.parse(arguments: args))
        #expect(launch.workspaceID == WorkspaceObjectID(workspace))
        #expect(launch.deviceID == WorkspaceObjectID(device))
        #expect(launch.containerRoot.path == "/tmp/disposable-preview")
        for invalid in [Array(args.dropLast()), Array(args.dropLast(2)), args + ["--agent-tooling-device-id", device.uuidString],
                        ["AgentTooling", "--agent-tooling-device-id", device.uuidString]] {
            #expect(throws: (any Error).self) { try WorkspacePreviewLaunch.parse(arguments: invalid) }
        }
        for flag in ["--agent-tooling-versioned-preview-root", "--agent-tooling-workspace-id", "--agent-tooling-device-id"] {
            #expect(throws: (any Error).self) {
                try WorkspacePreviewLaunch.parse(arguments: ["AgentTooling", flag + "=invalid"])
            }
        }
    }

    @Test @MainActor func nonexistentPreviewFailsWithoutCreatingItsContainer() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "missing-preview-\(UUID())")
        let launch = WorkspacePreviewLaunch(containerRoot: root, workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID())
        #expect(throws: WorkspaceRevisionStoreError.self) { try launch.openSession() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
