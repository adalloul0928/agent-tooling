import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

struct CentralPackageContentStoreTests {
    @Test func roundTripsCompleteTreeAndRetainsOlderVersionAfterReopen() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try tree("one"); let second = try tree("two")
        let store = try CentralPackageContentStore(directory: fixture.root)
        let receipt = try await store.store(first)
        #expect(receipt.digest == first.digest && receipt.entryCount == first.entries.count)
        #expect(receipt.totalFileBytes == first.totalFileBytes)
        _ = try await store.store(second)
        let reopened = try CentralPackageContentStore(directory: fixture.root)
        #expect(try await reopened.read(first.digest) == first)
        #expect(try await reopened.read(second.digest) == second)
        #expect(try permissions(fixture.object(first)) == 0o500)
        #expect(try permissions(fixture.payload(first).appending(path: "run")) == 0o500)
        #expect(try permissions(fixture.payload(first).appending(path: "plugin.json")) == 0o400)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.payload(first).appending(path: "current").path) == "run")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "staging").path).isEmpty)
    }

    @Test func concurrentSameDigestPublishersVerifyOneObject() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let content = try tree("same")
        let left = try CentralPackageContentStore(directory: fixture.root)
        let right = try CentralPackageContentStore(directory: fixture.root)
        async let a = left.store(content)
        async let b = right.store(content)
        let receipts = try await [a, b]
        #expect(receipts.allSatisfy { $0.digest == content.digest })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "objects").path) == [content.digest.value])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "staging").path).isEmpty)
    }

    @Test func largeFlatTreeDoesNotAccumulateFileDescriptors() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let entries = (0..<1_000).map {
            PackageTreeEntry(relativePath: "f\($0)", kind: .file(bytes: Data("x".utf8), executable: false))
        }
        let large = try CapturedPackageTree(entries: entries)
        let store = try CentralPackageContentStore(directory: fixture.root)
        #expect(try await store.store(large).entryCount == 1_000)
        #expect(try await store.read(large.digest) == large)
    }

    @Test func existingCorruptionIsReportedWithoutOverwritingItOrAnOlderVersion() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try tree("old"); let second = try tree("new")
        let store = try CentralPackageContentStore(directory: fixture.root)
        _ = try await store.store(first); _ = try await store.store(second)
        let altered = fixture.payload(second).appending(path: "run")
        #expect(chmod(altered.path, 0o600) == 0)
        try Data("changed externally".utf8).write(to: altered)
        await #expect(throws: CentralPackageStoreError.corruptContent) { _ = try await store.read(second.digest) }
        await #expect(throws: CentralPackageStoreError.corruptContent) { _ = try await store.store(second) }
        #expect(try Data(contentsOf: altered) == Data("changed externally".utf8))
        #expect(try await store.read(first.digest) == first)
    }

    @Test func injectedRootGitMetadataCannotHideFromObjectVerification() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let content = try tree("safe")
        let store = try CentralPackageContentStore(directory: fixture.root)
        _ = try await store.store(content)
        let payload = fixture.payload(content)
        #expect(chmod(payload.path, 0o700) == 0)
        try Data("not part of this object".utf8).write(to: payload.appending(path: ".git"))
        await #expect(throws: CentralPackageStoreError.corruptContent) { _ = try await store.read(content.digest) }
        #expect(try Data(contentsOf: payload.appending(path: ".git")) == Data("not part of this object".utf8))
    }

    @Test func unknownNonemptyRootIsNotInitializedOrModified() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let sentinel = fixture.root.appending(path: "sentinel")
        try Data("keep".utf8).write(to: sentinel)
        #expect(throws: CentralPackageStoreError.invalidRoot) { _ = try CentralPackageContentStore(directory: fixture.root) }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["sentinel"])
    }

    @Test(arguments: ["agent-tooling-content-store.v99\n", "broken", ""])
    func unsupportedOrMalformedMarkerIsNotOverwritten(_ value: String) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try CentralPackageContentStore(directory: fixture.root)
        let marker = fixture.root.appending(path: "format")
        #expect(chmod(marker.path, 0o600) == 0)
        try Data(value.utf8).write(to: marker)
        #expect(throws: CentralPackageStoreError.invalidRoot) { _ = try CentralPackageContentStore(directory: fixture.root) }
        let content = try tree("new")
        await #expect(throws: CentralPackageStoreError.changedStore) { _ = try await store.store(content) }
        #expect(try Data(contentsOf: marker) == Data(value.utf8))
    }

    @Test(arguments: ["", "objects", "staging", "format"])
    func changedPrivatePermissionsInvalidateAnOpenStore(_ name: String) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try CentralPackageContentStore(directory: fixture.root)
        let content = try tree("private")
        _ = try await store.store(content)
        let path = name.isEmpty ? fixture.root : fixture.root.appending(path: name)
        #expect(chmod(path.path, name == "format" ? 0o666 : 0o777) == 0)
        await #expect(throws: CentralPackageStoreError.changedStore) { _ = try await store.read(content.digest) }
        await #expect(throws: CentralPackageStoreError.changedStore) { _ = try await store.store(content) }
        #expect(throws: CentralPackageStoreError.invalidRoot) { _ = try CentralPackageContentStore(directory: fixture.root) }
    }

    @Test(arguments: ["objects", "staging"])
    func replacingStorageDirectoryCannotRedirectReadsOrWrites(_ name: String) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try CentralPackageContentStore(directory: fixture.root)
        let content = try tree("before")
        _ = try await store.store(content)
        let original = fixture.root.appending(path: name)
        let detached = fixture.container.appending(path: "detached")
        let outside = try fixture.sentinelDirectory()
        try FileManager.default.moveItem(at: original, to: detached)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        await #expect(throws: CentralPackageStoreError.changedStore) { _ = try await store.read(content.digest) }
        let another = try tree("after")
        await #expect(throws: CentralPackageStoreError.changedStore) { _ = try await store.store(another) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel"])
        #expect(try Data(contentsOf: outside.appending(path: "sentinel")) == Data("keep".utf8))
    }

    @Test func replacingRootCannotRedirectWritesAndSymlinkRootsAreRejected() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try CentralPackageContentStore(directory: fixture.root)
        let outside = try fixture.sentinelDirectory()
        try FileManager.default.moveItem(at: fixture.root, to: fixture.container.appending(path: "detached"))
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: outside)
        #expect(throws: CentralPackageStoreError.invalidRoot) { _ = try CentralPackageContentStore(directory: fixture.root) }
        let content = try tree("new")
        await #expect(throws: CentralPackageStoreError.changedStore) { _ = try await store.store(content) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel"])
    }

    @Test func objectPayloadSymlinkIsNotFollowed() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try CentralPackageContentStore(directory: fixture.root)
        let content = try tree("original")
        _ = try await store.store(content)
        let outside = try fixture.sentinelDirectory()
        #expect(chmod(fixture.object(content).path, 0o700) == 0)
        #expect(chmod(fixture.payload(content).path, 0o700) == 0)
        try FileManager.default.moveItem(at: fixture.payload(content), to: fixture.container.appending(path: "detached"))
        try FileManager.default.createSymbolicLink(at: fixture.payload(content), withDestinationURL: outside)
        await #expect(throws: CentralPackageStoreError.corruptContent) { _ = try await store.read(content.digest) }
        await #expect(throws: CentralPackageStoreError.corruptContent) { _ = try await store.store(content) }
        #expect(try Data(contentsOf: outside.appending(path: "sentinel")) == Data("keep".utf8))
    }

    @Test func initializationContentionHasAnExplicitRetryableOutcome() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let descriptor = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: CentralPackageStoreError.busy) { _ = try CentralPackageContentStore(directory: fixture.root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        #expect(flock(descriptor, LOCK_UN) == 0)
        let store = try CentralPackageContentStore(directory: fixture.root)
        let content = try tree("retry")
        #expect(try await store.store(content).digest == content.digest)
    }

    @Test func cancelledAndOverLimitIntakePublishNothing() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try CentralPackageContentStore(directory: fixture.root)
        let content = try tree("cancel")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.store(content)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let limited = try CentralPackageContentStore(directory: fixture.root, limits: .init(maxTotalBytes: 1))
        await #expect(throws: PackageTreeError.limitExceeded) { _ = try await limited.store(content) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "objects").path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "staging").path).isEmpty)
    }

    @Test func malformedDigestIsRejectedBeforeLookingUpContent() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try CentralPackageContentStore(directory: fixture.root)
        await #expect(throws: CentralPackageStoreError.invalidDigest) { _ = try await store.read(.init(value: "../outside")) }
        await #expect(throws: CentralPackageStoreError.missingContent) { _ = try await store.read(.init(value: String(repeating: "a", count: 64))) }
    }

    private func tree(_ value: String) throws -> CapturedPackageTree {
        try .init(entries: [
            .init(relativePath: "empty", kind: .directory),
            .init(relativePath: "plugin.json", kind: .file(bytes: Data("{\"name\":\"native\",\"futureExtension\":[1,true]}\n".utf8), executable: false)),
            .init(relativePath: "run", kind: .file(bytes: Data(value.utf8), executable: true)),
            .init(relativePath: "current", kind: .symbolicLink(target: "run")),
        ])
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CentralPackageStoreError.ioFailure }
        return value.st_mode & 0o777
    }

    private struct Fixture {
        let container: URL
        let root: URL
        init() throws {
            container = FileManager.default.temporaryDirectory.appending(path: "central-content-\(UUID().uuidString)")
            root = container.appending(path: "store")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func object(_ tree: CapturedPackageTree) -> URL { root.appending(path: "objects/\(tree.digest.value)") }
        func payload(_ tree: CapturedPackageTree) -> URL { object(tree).appending(path: "payload") }
        func sentinelDirectory() throws -> URL {
            let url = container.appending(path: "outside")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("keep".utf8).write(to: url.appending(path: "sentinel"))
            return url
        }
        func remove() {
            Self.makeDirectoriesRemovable(container)
            try? FileManager.default.removeItem(at: container)
        }
        private static func makeDirectoriesRemovable(_ url: URL) {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { return }
            _ = chmod(url.path, 0o700)
            for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                makeDirectoriesRemovable(child)
            }
        }
    }
}
