import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Workspace migration pilot launch")
struct WorkspaceMigrationPilotLaunchTests {
    @Test func absentPilotFlagReturnsNil() throws {
        #expect(try WorkspaceMigrationPilotLaunch.parse(arguments: ["AgentTooling", "--agent-tooling-section", "skills"]) == nil)
    }

    @Test func explicitDescriptorAndDisposableHomeParse() throws {
        let launch = try #require(try WorkspaceMigrationPilotLaunch.parse(arguments: [
            "AgentTooling",
            "--agent-tooling-migration-review", "/tmp/pilot-review.json",
            "--agent-tooling-home", "/tmp/pilot-home"
        ]))
        #expect(launch.descriptorURL.path == "/tmp/pilot-review.json")
        #expect(launch.homeRoot.path == "/tmp/pilot-home")
    }

    @Test func missingHomeDuplicatesAndMixedLaunchesAreRejected() {
        let base = ["AgentTooling", "--agent-tooling-migration-review", "/tmp/pilot-review.json"]
        let valid = base + ["--agent-tooling-home", "/tmp/pilot-home"]
        let invalid: [[String]] = [
            base,
            valid + ["--agent-tooling-home", "/tmp/another-home"],
            valid + ["--agent-tooling-migration-review", "/tmp/another-review.json"],
            valid + ["--agent-tooling-versioned-preview-root", "/tmp/versioned"],
            valid + ["--agent-tooling-workspace", "/tmp/legacy"],
            ["AgentTooling", "--agent-tooling-migration-review=/tmp/pilot-review.json", "--agent-tooling-home", "/tmp/pilot-home"]
        ]
        for arguments in invalid {
            #expect(throws: (any Error).self) { try WorkspaceMigrationPilotLaunch.parse(arguments: arguments) }
        }
    }

    @Test func invalidPilotPathsAreRejectedWithoutTouchingFilesystem() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let invalid: [[String]] = [
            ["AgentTooling", "--agent-tooling-migration-review", "relative.json", "--agent-tooling-home", "/tmp/pilot-home"],
            ["AgentTooling", "--agent-tooling-migration-review", "/tmp/pilot-review.json", "--agent-tooling-home", "/"],
            ["AgentTooling", "--agent-tooling-migration-review", "/tmp/pilot\nreview.json", "--agent-tooling-home", "/tmp/pilot-home"],
            ["AgentTooling", "--agent-tooling-migration-review", "/tmp/pilot-review.json", "--agent-tooling-home", "relative-home"]
        ]
        for arguments in invalid {
            #expect(throws: (any Error).self) { try WorkspaceMigrationPilotLaunch.parse(arguments: arguments) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
    }

    @Test func canonicalBoundedDescriptorDecodesLocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = try fixture.location.encode()
        try fixture.writeDescriptor(bytes)

        let decoded = try fixture.launch.readLocation()
        #expect(decoded == fixture.location)
    }

    @Test func missingEmptyOversizedSymlinkAndDirectoryDescriptorsFailWithoutCreation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.children()

        #expect(throws: (any Error).self) { try fixture.launch.readLocation() }
        #expect(try fixture.children() == before)

        try Data().write(to: fixture.descriptor)
        #expect(throws: (any Error).self) { try fixture.launch.readLocation() }
        try FileManager.default.removeItem(at: fixture.descriptor)

        try Data(repeating: 0x61, count: 16 * 1_024 + 1).write(to: fixture.descriptor)
        #expect(throws: (any Error).self) { try fixture.launch.readLocation() }
        try FileManager.default.removeItem(at: fixture.descriptor)

        let target = fixture.root.appending(path: "target.json")
        let validBytes = try fixture.location.encode()
        try validBytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.descriptor, withDestinationURL: target)
        #expect(throws: (any Error).self) { try fixture.launch.readLocation() }
        try FileManager.default.removeItem(at: fixture.descriptor)

        try FileManager.default.createDirectory(at: fixture.descriptor, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try fixture.launch.readLocation() }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "migration-pilot-launch-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let descriptor: URL
        let location: WorkspaceMigrationReviewLocation

        init() throws {
            root = try WorkspaceMigrationPilotLaunchTests().temporaryRoot()
            home = root.appending(path: "home", directoryHint: .isDirectory)
            descriptor = root.appending(path: "review.json")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            location = .init(
                legacyRoot: root.appending(path: "legacy", directoryHint: .isDirectory),
                containerRoot: root.appending(path: "versioned", directoryHint: .isDirectory),
                checkpointRoot: root.appending(path: "checkpoints", directoryHint: .isDirectory),
                contentRoot: root.appending(path: "content", directoryHint: .isDirectory),
                workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID(), attemptID: WorkspaceObjectID()
            )
        }

        var launch: WorkspaceMigrationPilotLaunch {
            .init(descriptorURL: descriptor, homeRoot: home)
        }

        func writeDescriptor(_ data: Data) throws {
            try data.write(to: descriptor, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
        }

        func children() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
