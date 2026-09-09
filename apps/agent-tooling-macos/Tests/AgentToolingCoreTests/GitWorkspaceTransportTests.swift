import Foundation
import Testing

@testable import AgentToolingCore

/// Real Git against a local bare repository. Two checkouts stand in for two
/// Macs sharing one private workspace repository; this is not a two-Mac pilot.
@Suite("Git workspace transport")
struct GitWorkspaceTransportTests {
    @Test func anEmptyRepositoryHasNoHeadAndNoDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = try await fixture.enroll("a")

        let state = try await transport.remoteState()

        #expect(state.head == nil)
        #expect(state.document == nil)
    }

    @Test func aPublishedRevisionIsReadableByAnotherCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.enroll("a")
        let document = try Fixture.document(name: "Alpha")

        let receipt = try await first.publish(document: document, expectedRemoteHead: nil)

        #expect(receipt.previousHead == nil)
        #expect(receipt.revisionID == document.revision.id)
        let second = try await fixture.enroll("b")
        let state = try await second.remoteState()
        #expect(state.head == receipt.commit)
        #expect(state.document == document)
    }

    @Test func aRejectedPushReportsTheRemoteHeadAndNeverForces() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.enroll("a")
        let second = try await fixture.enroll("b")
        let mine = try Fixture.document(name: "Mine")
        let theirs = try Fixture.document(name: "Theirs")

        let published = try await second.publish(document: theirs, expectedRemoteHead: nil)

        await #expect(throws: GitWorkspaceTransportError.remoteAdvanced(remoteHead: published.commit)) {
            try await first.publish(document: mine, expectedRemoteHead: nil)
        }
        // The other Mac's revision is untouched.
        let state = try await second.remoteState()
        #expect(state.head == published.commit)
        #expect(state.document?.artifacts.first?.identity.displayName == "Theirs")
    }

    @Test func aRejectedPushIsResolvedByMergingAndPublishingTheResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.enroll("a")
        let second = try await fixture.enroll("b")
        let base = try Fixture.document(name: "Shared")
        let published = try await first.publish(document: base, expectedRemoteHead: nil)

        // Each side changes a different item from the same ancestor.
        var mine = base
        mine.artifacts[0].identity.displayName = "Shared on A"
        mine.revision = .init(parentIDs: [base.revision.id], writerID: base.revision.writerID)
        mine = try WorkspaceDocumentCoding.seal(mine)
        var theirs = base
        theirs.artifacts[1].identity.displayName = "Second on B"
        theirs.revision = .init(parentIDs: [base.revision.id], writerID: base.revision.writerID)
        theirs = try WorkspaceDocumentCoding.seal(theirs)

        let theirCommit = try await second.publish(document: theirs, expectedRemoteHead: published.commit)
        await #expect(throws: GitWorkspaceTransportError.remoteAdvanced(remoteHead: theirCommit.commit)) {
            try await first.publish(document: mine, expectedRemoteHead: published.commit)
        }

        let remote = try await first.remoteState()
        let remoteDocument = try #require(remote.document)
        let merged = WorkspaceMergeEngine.merge(base: base, local: mine, remote: remoteDocument,
                                                writerID: base.revision.writerID)
        #expect(merged.isResolved, "\(merged.conflicts)")
        let sealed = try WorkspaceDocumentCoding.seal(try #require(merged.document))
        let mergeCommit = try await first.publish(document: sealed, expectedRemoteHead: remote.head)

        let converged = try await second.remoteState()
        #expect(converged.head == mergeCommit.commit)
        let names = Set((converged.document?.artifacts ?? []).map(\.identity.displayName))
        #expect(names == ["Shared on A", "Second on B"])
        #expect(converged.document?.revision.parentIDs.count == 2)
    }

    @Test func unrelatedWorkingTreeChangesStopAPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = try await fixture.enroll("a")
        try Data("not ours\n".utf8).write(to: fixture.checkout("a").appending(path: "notes.txt"))

        await #expect(throws: GitWorkspaceTransportError.unrelatedWorkingTreeChanges) {
            try await transport.publish(document: try Fixture.document(name: "Alpha"),
                                        expectedRemoteHead: nil)
        }
        // Nothing was committed on the person's behalf.
        let state = try await transport.remoteState()
        #expect(state.head == nil)
    }

    @Test func onlyAnExplicitCredentialFreeRemoteIsAccepted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for remote in ["https://token:secret@github.com/owner/workspace.git",
                       "--upload-pack=/bin/sh",
                       "ftp://example.com/workspace.git",
                       "https://exam\u{0}ple.com/x.git"] {
            await #expect(throws: GitWorkspaceTransportError.invalidRemote) {
                _ = try await GitWorkspaceTransport.enroll(
                    remote: remote, checkout: fixture.checkout("rejected"))
            }
        }
        for branch in ["", "-main", "feature..x", "main.lock", "with space"] {
            #expect(throws: GitWorkspaceTransportError.invalidCheckout) {
                _ = try GitWorkspaceTransport(checkout: fixture.checkout("a"), branch: branch)
            }
        }
    }

    private struct Fixture {
        let root: URL
        let remote: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "git-workspace-transport-\(UUID())")
            remote = root.appending(path: "remote.git")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Self.run(["init", "--bare", "--initial-branch", "main", remote.path], in: root)
        }

        func checkout(_ name: String) -> URL { root.appending(path: name) }

        func enroll(_ name: String) async throws -> GitWorkspaceTransport {
            let transport = try await GitWorkspaceTransport.enroll(
                remote: remote.path, checkout: checkout(name))
            // A fresh repository needs an identity before it can commit.
            try Self.run(["config", "user.email", "fixture@example.com"], in: checkout(name))
            try Self.run(["config", "user.name", "Fixture"], in: checkout(name))
            return transport
        }

        static func document(name: String) throws -> PortableWorkspaceDocument {
            let writerID = WorkspaceObjectID()
            return try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!),
                revision: .init(writerID: writerID),
                artifacts: [
                    .init(identity: .init(id: ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!),
                                          kind: .skill, displayName: name),
                          authority: .trackedOnly),
                    .init(identity: .init(id: ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!),
                                          kind: .skill, displayName: "Second"),
                          authority: .trackedOnly),
                ]))
        }

        @discardableResult
        static func run(_ arguments: [String], in directory: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
