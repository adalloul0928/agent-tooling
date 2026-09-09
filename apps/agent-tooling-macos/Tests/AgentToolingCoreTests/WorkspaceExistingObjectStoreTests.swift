import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceExistingObjectStoreTests {
    @Test func missingAndEmptyRootsAreRejectedWithoutInitialization() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "existing-object-stores-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appending(path: "content")
        let checkpoints = root.appending(path: "checkpoints")
        #expect(throws: CentralPackageStoreError.self) {
            _ = try CentralPackageContentStore(directory: content, initializeIfEmpty: false)
        }
        #expect(throws: WorkspaceLegacyCheckpointStoreError.self) {
            _ = try WorkspaceLegacyCheckpointStore(directory: checkpoints, initializeIfEmpty: false)
        }
        #expect(FileManager.default.fileExists(atPath: content.path) == false)
        #expect(FileManager.default.fileExists(atPath: checkpoints.path) == false)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(throws: CentralPackageStoreError.self) {
            _ = try CentralPackageContentStore(directory: content, initializeIfEmpty: false)
        }
        #expect(throws: WorkspaceLegacyCheckpointStoreError.self) {
            _ = try WorkspaceLegacyCheckpointStore(directory: checkpoints, initializeIfEmpty: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: content.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: checkpoints.path).isEmpty)
    }

    @Test func initializedStoresCanReopenWithoutCreatingOrChangingObjects() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "existing-object-stores-valid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let contentURL = root.appending(path: "content")
        let checkpointURL = root.appending(path: "checkpoints")
        try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: checkpointURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try CentralPackageContentStore(directory: contentURL)
        _ = try WorkspaceLegacyCheckpointStore(directory: checkpointURL)
        let contentBefore = try FileManager.default.contentsOfDirectory(atPath: contentURL.path).sorted()
        let checkpointBefore = try FileManager.default.contentsOfDirectory(atPath: checkpointURL.path).sorted()
        _ = try CentralPackageContentStore(directory: contentURL, initializeIfEmpty: false)
        _ = try WorkspaceLegacyCheckpointStore(directory: checkpointURL, initializeIfEmpty: false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: contentURL.path).sorted() == contentBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: checkpointURL.path).sorted() == checkpointBefore)
    }

    @Test func partialRootsRejectWithoutRepairingMissingChildDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "existing-object-stores-partial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let contentURL = root.appending(path: "content")
        let checkpointURL = root.appending(path: "checkpoints")
        try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: checkpointURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try CentralPackageContentStore(directory: contentURL)
        _ = try WorkspaceLegacyCheckpointStore(directory: checkpointURL)
        try FileManager.default.removeItem(at: contentURL.appending(path: "staging"))
        try FileManager.default.removeItem(at: checkpointURL.appending(path: "objects"))
        #expect(throws: CentralPackageStoreError.self) {
            _ = try CentralPackageContentStore(directory: contentURL, initializeIfEmpty: false)
        }
        #expect(throws: WorkspaceLegacyCheckpointStoreError.self) {
            _ = try WorkspaceLegacyCheckpointStore(directory: checkpointURL, initializeIfEmpty: false)
        }
        #expect(FileManager.default.fileExists(atPath: contentURL.appending(path: "staging").path) == false)
        #expect(FileManager.default.fileExists(atPath: checkpointURL.appending(path: "objects").path) == false)
    }
}
