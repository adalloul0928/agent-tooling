import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceLegacyCheckpointStoreTests {
    @Test func savesReadsAndReopensAnImmutableCheckpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = try await fixture.checkpoint(named: "original")
        let store = try WorkspaceLegacyCheckpointStore(directory: fixture.storeRoot)

        #expect(try await store.save(checkpoint) == checkpoint.sha256)
        let read = try await store.read(checkpoint.sha256)
        #expect(read.sha256 == checkpoint.sha256)
        #expect(read.databaseBytes == checkpoint.databaseBytes)
        #expect(try read.workspaceSnapshot()?.skills.first?.id == "original")

        let reopened = try WorkspaceLegacyCheckpointStore(directory: fixture.storeRoot)
        #expect(try await reopened.read(checkpoint.sha256).databaseBytes == checkpoint.databaseBytes)
        #expect(try await reopened.save(checkpoint) == checkpoint.sha256)
        #expect(try fixture.objectNames() == [checkpoint.sha256])
    }

    @Test func concurrentSameCheckpointPublishersConvergeWithoutReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = try await fixture.checkpoint(named: "same")
        let left = try WorkspaceLegacyCheckpointStore(directory: fixture.storeRoot)
        let right = try WorkspaceLegacyCheckpointStore(directory: fixture.storeRoot)

        async let first = left.save(checkpoint)
        async let second = right.save(checkpoint)
        let saved = try await [first, second]
        #expect(saved == [checkpoint.sha256, checkpoint.sha256])
        #expect(try fixture.objectNames() == [checkpoint.sha256])
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test func existingTamperedObjectIsReportedAndNeverReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = try await fixture.checkpoint(named: "tamper")
        let store = try WorkspaceLegacyCheckpointStore(directory: fixture.storeRoot)
        _ = try await store.save(checkpoint)
        let object = fixture.object(checkpoint.sha256)
        #expect(chmod(object.path, 0o600) == 0)
        let altered = Data("changed checkpoint".utf8)
        try altered.write(to: object)

        await #expect(throws: WorkspaceLegacyCheckpointStoreError.corruptCheckpoint) {
            _ = try await store.read(checkpoint.sha256)
        }
        await #expect(throws: WorkspaceLegacyCheckpointStoreError.corruptCheckpoint) {
            _ = try await store.save(checkpoint)
        }
        #expect(try Data(contentsOf: object) == altered)
    }

    @Test func malformedMissingAndHardLinkedObjectsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = try await fixture.checkpoint(named: "linked")
        let store = try WorkspaceLegacyCheckpointStore(directory: fixture.storeRoot)

        await #expect(throws: WorkspaceLegacyCheckpointStoreError.invalidDigest) {
            _ = try await store.read("../outside")
        }
        await #expect(throws: WorkspaceLegacyCheckpointStoreError.missingCheckpoint) {
            _ = try await store.read(String(repeating: "a", count: 64))
        }
        _ = try await store.save(checkpoint)
        try FileManager.default.linkItem(
            at: fixture.object(checkpoint.sha256),
            to: fixture.container.appending(path: "extra-link"))
        await #expect(throws: WorkspaceLegacyCheckpointStoreError.corruptCheckpoint) {
            _ = try await store.read(checkpoint.sha256)
        }
    }

    @Test func requiresAnExistingPrivateOwnedDedicatedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.container.appending(path: "missing")
        #expect(throws: WorkspaceLegacyCheckpointStoreError.invalidRoot) {
            _ = try WorkspaceLegacyCheckpointStore(directory: missing)
        }

        let publicRoot = fixture.container.appending(path: "public")
        try FileManager.default.createDirectory(at: publicRoot, withIntermediateDirectories: false)
        #expect(chmod(publicRoot.path, 0o777) == 0)
        #expect(throws: WorkspaceLegacyCheckpointStoreError.invalidRoot) {
            _ = try WorkspaceLegacyCheckpointStore(directory: publicRoot)
        }

        let link = fixture.container.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.storeRoot)
        #expect(throws: WorkspaceLegacyCheckpointStoreError.invalidRoot) {
            _ = try WorkspaceLegacyCheckpointStore(directory: link)
        }
    }

    @Test func replacedStorageDirectoryCannotRedirectAnOpenStore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkpoint = try await fixture.checkpoint(named: "binding")
        let store = try WorkspaceLegacyCheckpointStore(directory: fixture.storeRoot)
        _ = try await store.save(checkpoint)
        let objects = fixture.storeRoot.appending(path: "objects")
        try FileManager.default.moveItem(at: objects, to: fixture.container.appending(path: "detached"))
        let outside = fixture.container.appending(path: "outside")
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: objects, withDestinationURL: outside)

        await #expect(throws: WorkspaceLegacyCheckpointStoreError.changedStore) {
            _ = try await store.read(checkpoint.sha256)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    private struct Fixture {
        let container: URL
        let storeRoot: URL

        init() throws {
            container = FileManager.default.temporaryDirectory
                .appending(path: "legacy-checkpoint-store-\(UUID().uuidString)")
            storeRoot = container.appending(path: "checkpoints")
            try FileManager.default.createDirectory(
                at: storeRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        func checkpoint(named name: String) async throws -> WorkspaceLegacyCheckpoint {
            let legacyRoot = container.appending(path: "legacy-\(name)")
            let legacy = try WorkspaceStore(rootURL: legacyRoot)
            try legacy.saveWorkspaceSnapshot(.init(
                skills: [.init(
                    id: name, name: name, displayName: name, summary: "", bundle: "standalone",
                    scope: "This Mac", owned: false, triggers: [], negativeTrigger: "",
                    files: ["SKILL.md"], clients: [], validationCount: 1)],
                activeProfileID: ""))
            return try await WorkspaceLegacyCheckpoint.capture(databaseURL: legacy.databaseURL)
        }

        func object(_ digest: String) -> URL {
            storeRoot.appending(path: "objects/\(digest)")
        }

        func objectNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: storeRoot.appending(path: "objects").path).sorted()
        }

        func stagingNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: storeRoot.appending(path: "staging").path).sorted()
        }

        func remove() {
            Self.makeRemovable(container)
            try? FileManager.default.removeItem(at: container)
        }

        private static func makeRemovable(_ url: URL) {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { return }
            if value.st_mode & S_IFMT == S_IFDIR {
                _ = chmod(url.path, 0o700)
                for child in (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)) ?? [] {
                    makeRemovable(child)
                }
            } else {
                _ = chmod(url.path, 0o600)
            }
        }
    }
}
