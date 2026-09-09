import Foundation
import Testing

@testable import AgentToolingCore

/// This Mac's connection to a shared repository. It carries no credential and
/// is never part of portable bytes.
@Suite("Workspace sync enrollment")
struct WorkspaceSyncEnrollmentTests {
    @Test func aSavedConnectionSurvivesReopeningAndCarriesNoCredential() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try WorkspaceSyncEnrollment(
            workspaceID: fixture.workspaceID, remote: "https://github.com/you/workspace.git",
            checkoutPath: fixture.checkout.path)

        try fixture.store.write(record)
        let reopened = try WorkspaceSyncEnrollmentStore(containerRoot: fixture.root).read()

        #expect(reopened == record)
        let bytes = try Data(contentsOf: fixture.root.appending(path: "sync-enrollment.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("password") && !text.contains("token") && !text.contains("@github.com"))
    }

    @Test func automaticSyncingIsOnByDefaultAndAnOlderRecordStillReadsThatWay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try WorkspaceSyncEnrollment(
            workspaceID: fixture.workspaceID, remote: "https://github.com/you/workspace.git",
            checkoutPath: fixture.checkout.path)
        #expect(record.isAutomatic)

        // Written before the field existed: connecting already meant this, so
        // that is what it keeps meaning rather than becoming a refusal to read.
        let file = fixture.root.appending(path: "sync-enrollment.json")
        try Data("""
            {"formatVersion":1,"workspaceID":"\(fixture.workspaceID.rawValue.uuidString.lowercased())",\
            "remote":"https://github.com/you/workspace.git",\
            "checkoutPath":"\(fixture.checkout.path)","branch":"main"}
            """.replacingOccurrences(of: "\\\n", with: "").utf8).write(to: file)

        let reopened = try #require(try WorkspaceSyncEnrollmentStore(containerRoot: fixture.root).read())
        #expect(reopened.isAutomatic)
    }

    @Test func turningAutomaticSyncingOffKeepsEverythingElseAboutTheConnection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try WorkspaceSyncEnrollment(
            workspaceID: fixture.workspaceID, remote: "https://github.com/you/workspace.git",
            checkoutPath: fixture.checkout.path)

        let off = try record.settingAutomatic(false)
        try fixture.store.write(off)

        #expect(!off.isAutomatic)
        #expect(off.remote == record.remote && off.checkoutPath == record.checkoutPath
            && off.branch == record.branch && off.workspaceID == record.workspaceID)
        #expect(try WorkspaceSyncEnrollmentStore(containerRoot: fixture.root).read() == off)
    }

    @Test func aRemoteCarryingCredentialsOrAnUnsafePathIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for remote in ["https://token:secret@github.com/you/workspace.git",
                       "--upload-pack=/bin/sh", "ftp://example.com/x.git"] {
            #expect(throws: WorkspaceSyncEnrollmentError.invalidRemote) {
                _ = try WorkspaceSyncEnrollment(workspaceID: fixture.workspaceID, remote: remote,
                                                checkoutPath: fixture.checkout.path)
            }
        }
        for path in ["relative/path", "/tmp/with\u{0}null"] {
            #expect(throws: WorkspaceSyncEnrollmentError.invalidCheckout) {
                _ = try WorkspaceSyncEnrollment(workspaceID: fixture.workspaceID,
                                                remote: "https://github.com/you/workspace.git",
                                                checkoutPath: path)
            }
        }
    }

    @Test func noConnectionReadsAsNilWhileADamagedFileIsAnError() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.store.read() == nil)

        try Data("{\"formatVersion\":99}".utf8)
            .write(to: fixture.root.appending(path: "sync-enrollment.json"))

        // A file this build cannot read is never silently "not connected".
        #expect(throws: WorkspaceSyncEnrollmentError.unsupportedFormat) { _ = try fixture.store.read() }
    }

    @Test func disconnectingClearsOnlyThisMacsRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.write(try .init(workspaceID: fixture.workspaceID,
                                          remote: "https://github.com/you/workspace.git",
                                          checkoutPath: fixture.checkout.path))

        try fixture.store.remove()

        #expect(try fixture.store.read() == nil)
        // Removing again is not an error.
        #expect(throws: Never.self) { try fixture.store.remove() }
        // The checkout folder itself is untouched.
        #expect(FileManager.default.fileExists(atPath: fixture.checkout.path))
    }

    private struct Fixture {
        let root: URL
        let checkout: URL
        let store: WorkspaceSyncEnrollmentStore
        let workspaceID = WorkspaceObjectID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "sync-enrollment-\(UUID())")
            checkout = root.appending(path: "checkout")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            store = try WorkspaceSyncEnrollmentStore(containerRoot: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
