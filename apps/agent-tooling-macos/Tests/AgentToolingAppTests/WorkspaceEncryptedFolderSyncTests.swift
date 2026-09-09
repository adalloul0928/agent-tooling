import CryptoKit
import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// Connecting a folder a file-sync service keeps in step. The first Mac makes a
/// key and shows it once; a second Mac opens the same folder with that phrase,
/// and a wrong one is refused rather than sealing the folder against itself.
@MainActor
struct WorkspaceEncryptedFolderSyncTests {
    @Test func theFirstMacMakesAKeyAndShowsThePhraseOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(fixture.macA)

        await session.connectFolder(fixture.shared, phrase: "")

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.isConnected)
        #expect(session.enrollment?.kind == .encryptedFolder)
        let phrase = try #require(session.recoveryPhrase)
        #expect(!phrase.isEmpty)
        // Shown once, and this app has no way to show it again.
        session.dismissRecoveryPhrase()
        #expect(session.recoveryPhrase == nil)
        let reopened = fixture.session(fixture.macA)
        reopened.load()
        #expect(reopened.recoveryPhrase == nil)
        #expect(reopened.isConnected, "\(reopened.errorMessage ?? "")")
    }

    @Test func aSecondMacOpensTheSameFolderWithThatPhrase() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = fixture.session(fixture.macA)
        await a.connectFolder(fixture.shared, phrase: "")
        let phrase = try #require(a.recoveryPhrase)
        await a.sync()
        #expect(a.errorMessage == nil, "\(a.errorMessage ?? "")")

        let b = fixture.session(fixture.macB)
        await b.connectFolder(fixture.shared, phrase: phrase)
        await b.sync()

        #expect(b.errorMessage == nil, "\(b.errorMessage ?? "")")
        // The second Mac made no new key, so it read what the first published.
        #expect(b.recoveryPhrase == nil)
        #expect(try fixture.storeB.snapshot()?.document.artifacts.first?.identity.displayName == "Alpha")
    }

    @Test func aWrongPhraseIsRefusedRatherThanSealingTheFolderAgainstItself() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = fixture.session(fixture.macA)
        await a.connectFolder(fixture.shared, phrase: "")
        await a.sync()
        let sealed = try Data(contentsOf: fixture.shared
            .appending(path: EncryptedFolderWorkspaceTransport.documentFileName))

        let b = fixture.session(fixture.macB)
        let stranger = WorkspaceFolderKeyStore.recoveryPhrase(for: WorkspaceFolderKeyStore.generate())
        await b.connectFolder(fixture.shared, phrase: stranger)

        #expect(!b.isConnected)
        #expect(b.errorMessage?.contains("does not open") == true, "\(b.errorMessage ?? "")")
        // What the first Mac published is exactly as it was.
        #expect(try Data(contentsOf: fixture.shared
            .appending(path: EncryptedFolderWorkspaceTransport.documentFileName)) == sealed)
    }

    @Test func somethingThatIsNotAPhraseIsSaidToNotBeOne() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(fixture.macA)

        await session.connectFolder(fixture.shared, phrase: "not a phrase")

        #expect(!session.isConnected)
        #expect(session.errorMessage?.contains("not a phrase from another Mac") == true,
                "\(session.errorMessage ?? "")")
    }

    @Test func disconnectingForgetsTheKeyAndLeavesTheFolderSealed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = fixture.session(fixture.macA)
        await a.connectFolder(fixture.shared, phrase: "")
        let phrase = try #require(a.recoveryPhrase)
        await a.sync()

        a.disconnect()

        #expect(!a.isConnected)
        #expect(try WorkspaceFolderKeyStore(containerRoot: fixture.macA).read() == nil)
        // Still there, still sealed, and still readable where the phrase is.
        let transport = try EncryptedFolderWorkspaceTransport(
            folder: fixture.shared, key: try WorkspaceFolderKeyStore.key(fromRecoveryPhrase: phrase))
        #expect(try await transport.remoteState().document?.artifacts.count == 1)
    }

    @Test func nothingInThatFolderNamesAnythingInTheLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(fixture.macA)
        await session.connectFolder(fixture.shared, phrase: "")

        await session.sync()

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        for name in try FileManager.default.contentsOfDirectory(atPath: fixture.shared.path) {
            let text = String(decoding: try Data(contentsOf: fixture.shared.appending(path: name)),
                              as: UTF8.self)
            #expect(!text.contains("Alpha"), "\(name) leaks a name from the library")
        }
    }

    @MainActor private struct Fixture {
        static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        let root: URL
        let shared: URL
        let macA: URL
        let macB: URL
        let storeA: WorkspaceRevisionStore
        let storeB: WorkspaceRevisionStore
        let workspaceID: WorkspaceObjectID

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "folder-sync-\(UUID())")
            shared = root.appending(path: "shared")
            macA = root.appending(path: "mac-a")
            macB = root.appending(path: "mac-b")
            for url in [shared, macA, macB] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!)
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: workspaceID,
                revision: .init(id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f6")!),
                                writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f7")!),
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
                artifacts: [.init(identity: .init(id: Self.alpha, kind: .skill, displayName: "Alpha"),
                                  authority: .trackedOnly)]))
            storeA = try WorkspaceRevisionStore(containerRoot: macA.appending(path: "store"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try storeA.initialize(document: document,
                                  device: .init(workspaceID: workspaceID, deviceID: storeA.deviceID))
            storeB = try WorkspaceRevisionStore(containerRoot: macB.appending(path: "store"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try storeB.initialize(document: document,
                                  device: .init(workspaceID: workspaceID, deviceID: storeB.deviceID))
        }

        func session(_ container: URL) -> WorkspaceSyncSession {
            let store = container == macA ? storeA : storeB
            return WorkspaceSyncSession(
                store: store,
                enrollmentStore: try! WorkspaceSyncEnrollmentStore(containerRoot: container),
                workspaceID: workspaceID, writerID: WorkspaceObjectID(),
                keyStore: try! WorkspaceFolderKeyStore(containerRoot: container))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
