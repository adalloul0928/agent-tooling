import AgentToolingTestSupport
import CryptoKit
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

@MainActor
struct WorkspaceSyncConnectionIdentityTests {
    @Test(arguments: WorkspaceSyncTransportKind.allCases)
    func anotherLibraryCannotReplaceTheCurrentConnection(kind: WorkspaceSyncTransportKind) async throws {
        let fixture = try GitLibraryFixture("foreign-sync-connection")
        defer { fixture.remove() }
        let publisher = try await fixture.publishLibrary(from: "Juniper", skills: ["review-skill"])
        let home = try fixture.home("Cedar")
        let support = fixture.root.appending(path: "Cedar/support")
        let local = try await WorkspaceLocator(root: support).create(
            homeURL: home, runner: RefusingCommandRunner(), registry: ClientAdapterRegistry(adapters: []), preferences: nil)
        let container = local.databaseURL.deletingLastPathComponent()
        let enrollmentStore = try WorkspaceSyncEnrollmentStore(containerRoot: container)
        let keyStore = try WorkspaceFolderKeyStore(containerRoot: container)
        let session = WorkspaceSyncSession(
            store: local, enrollmentStore: enrollmentStore, workspaceID: local.workspaceID,
            writerID: WorkspaceObjectID(), keyStore: keyStore)
        let currentFolder = fixture.root.appending(path: "current-folder")
        try FileManager.default.createDirectory(at: currentFolder, withIntermediateDirectories: true)
        await session.connectFolder(currentFolder, phrase: "")
        let previousEnrollment = try #require(session.enrollment)
        let previousKey = try #require(try keyStore.read())
        let previousSnapshot = try #require(try local.snapshot())
        let previousLocator = try WorkspaceLocator(root: support).read()

        switch kind {
        case .git:
            await session.connect(remote: fixture.remote.path, checkout: fixture.root.appending(path: "foreign-checkout"))
        case .encryptedFolder:
            let remoteFolder = fixture.root.appending(path: "foreign-folder")
            try FileManager.default.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
            let remoteKey = WorkspaceFolderKeyStore.generate()
            let transport = try EncryptedFolderWorkspaceTransport(folder: remoteFolder, key: remoteKey)
            let document = try #require(try publisher.store.snapshot()).document
            _ = try await transport.publish(
                document: document, ancestors: publisher.store.revisionHistory(from: document.revision.id), expectedRemoteHead: nil)
            let sealed = try Data(contentsOf: remoteFolder.appending(path: EncryptedFolderWorkspaceTransport.documentFileName))
            await session.connectFolder(remoteFolder, phrase: WorkspaceFolderKeyStore.recoveryPhrase(for: remoteKey))
            #expect(try Data(contentsOf: remoteFolder.appending(path: EncryptedFolderWorkspaceTransport.documentFileName)) == sealed)
        }

        #expect(session.enrollment == previousEnrollment)
        #expect(try enrollmentStore.read() == previousEnrollment)
        #expect(
            try keyStore.read().map(WorkspaceFolderKeyStore.recoveryPhrase(for:))
                == WorkspaceFolderKeyStore.recoveryPhrase(for: previousKey))
        #expect(try local.snapshot()?.document == previousSnapshot.document)
        #expect(try WorkspaceLocator(root: support).read() == previousLocator)
        #expect(session.errorMessage?.contains("another library") == true)
        #expect(session.errorMessage?.contains("during setup") == true)
        #expect(session.errorMessage?.contains("connection was kept") == true)
        // The rejected candidate never becomes the active transport.
        await session.sync()
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: currentFolder.path).contains(
                EncryptedFolderWorkspaceTransport.documentFileName))
    }
}
