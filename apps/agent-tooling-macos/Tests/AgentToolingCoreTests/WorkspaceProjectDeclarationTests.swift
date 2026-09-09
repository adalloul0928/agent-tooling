import Foundation
import Testing

@testable import AgentToolingCore

/// A project's own declaration and lock. Meant to be committed, so they diff
/// cleanly, carry nothing machine-specific, and never overwrite a file this app
/// did not write.
@Suite("Workspace project declaration")
struct WorkspaceProjectDeclarationTests {
    @Test func whatIsWrittenIsWhatComesBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.store.write(declaration: try Self.declaration(), lock: try Self.lock())

        #expect(try fixture.store.readDeclaration() == (try Self.declaration()))
        #expect(try fixture.store.readLock() == (try Self.lock()))
    }

    @Test func theSameInputsProduceByteIdenticalFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // Written in one order, then the reverse. A file meant to be committed
        // must not churn a diff because a dictionary iterated differently.
        try fixture.store.write(declaration: try Self.declaration(), lock: nil)
        let first = try Data(contentsOf: fixture.store.declarationURL)
        try fixture.store.write(declaration: try Self.declaration(reversed: true), lock: nil)
        let second = try Data(contentsOf: fixture.store.declarationURL)

        #expect(first == second)
        #expect(first.last == 0x0A, "a committed text file should end in a newline")
    }

    @Test func nothingMachineSpecificReachesEitherFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.store.write(declaration: try Self.declaration(), lock: try Self.lock())

        for url in [fixture.store.declarationURL, fixture.store.lockURL] {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            #expect(!text.contains("/Users/"), "\(url.lastPathComponent) carries a path")
            #expect(!text.contains(fixture.root.path))
            // No observation timestamps and no device identity.
            for noise in ["observedAt", "lastScannedAt", "createdAt", "deviceID", "token", "password"] {
                #expect(!text.contains(noise), "\(url.lastPathComponent) carries \(noise)")
            }
        }
    }

    @Test func onlyACommitHashCountsAsALock() throws {
        // A version tag can be re-pointed and an opaque publisher revision makes
        // no promise this build can check. Neither restores the same bytes later.
        for revision in [SourceRevision(kind: .semanticVersion, value: "1.2.0"),
                         .init(kind: .opaquePublisherRevision, value: "release-7"),
                         .init(kind: .gitCommitSHA1, value: "abc"),
                         .init(kind: .gitCommitSHA1, value: String(repeating: "z", count: 40))] {
            #expect(throws: WorkspaceProjectDeclarationError.mutableRevision(name: "reviewer")) {
                _ = try WorkspaceProjectLock(entries: [
                    .init(name: "reviewer", kind: .skill, revision: revision,
                          contentDigest: .init(value: String(repeating: "a", count: 64))),
                ])
            }
        }
        // Both commit-hash algorithms are immutable and both are accepted.
        #expect(throws: Never.self) {
            _ = try WorkspaceProjectLock(entries: [
                .init(name: "reviewer", kind: .skill,
                      revision: .init(kind: .gitCommitSHA256, value: String(repeating: "a", count: 64)),
                      contentDigest: .init(value: String(repeating: "b", count: 64))),
            ])
        }
    }

    @Test func whatWasAskedForIsKeptBesideWhatItTurnedOutToBe() throws {
        let lock = try Self.lock()

        // Two different facts. Losing the first makes the lock unexplainable.
        #expect(lock.entries.first?.requestedRef == "main")
        #expect(lock.entries.first?.revision.value == String(repeating: "a", count: 40))
    }

    @Test func aCredentialInASourceAddressIsRefused() throws {
        for url in ["https://token:secret@github.com/you/skills",
                    "https://github.com/you/skills?access_token=abc",
                    "http://github.com/you/skills"] {
            #expect(throws: WorkspaceProjectDeclarationError.invalidEntry(name: "reviewer")) {
                _ = try WorkspaceProjectDeclaration(entries: [
                    .init(name: "reviewer", kind: .skill, repositoryURL: url),
                ])
            }
        }
    }

    @Test func aMachinesOwnPathIsNotAPackagePath() throws {
        for path in ["/Users/me/skills", "../escaped", "skills/../..", ""] {
            #expect(throws: WorkspaceProjectDeclarationError.invalidEntry(name: "reviewer")) {
                _ = try WorkspaceProjectDeclaration(entries: [
                    .init(name: "reviewer", kind: .skill, packageRelativePath: path),
                ])
            }
        }
    }

    @Test func oneNameAndKindAppearsOnce() throws {
        #expect(throws: WorkspaceProjectDeclarationError.duplicateEntry(name: "reviewer")) {
            _ = try WorkspaceProjectDeclaration(entries: [
                .init(name: "reviewer", kind: .skill), .init(name: "reviewer", kind: .skill),
            ])
        }
        // The same name for two different kinds is not a duplicate.
        #expect(throws: Never.self) {
            _ = try WorkspaceProjectDeclaration(entries: [
                .init(name: "reviewer", kind: .skill), .init(name: "reviewer", kind: .mcpServer),
            ])
        }
    }

    @Test func aFileThisAppDidNotWriteIsNeverOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.store.declarationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let theirs = Data(#"{"marker":"some-other-tool","entries":[]}"#.utf8)
        try theirs.write(to: fixture.store.declarationURL)

        #expect(throws: WorkspaceProjectDeclarationError.self) {
            try fixture.store.write(declaration: try Self.declaration(), lock: try Self.lock())
        }
        #expect(try Data(contentsOf: fixture.store.declarationURL) == theirs)
        // Refused before anything was written, so the pair is never half-updated.
        #expect(!FileManager.default.fileExists(atPath: fixture.store.lockURL.path))
    }

    @Test func aFileFromAFormatThisBuildDoesNotKnowIsRefusedRatherThanGuessedAt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.write(declaration: try Self.declaration(), lock: nil)
        try Data(#"{"marker":"agent-tooling.project.v1","formatVersion":99,"entries":[]}"#.utf8)
            .write(to: fixture.store.declarationURL)

        #expect(throws: WorkspaceProjectDeclarationError.unsupportedFormat) {
            _ = try fixture.store.readDeclaration()
        }
    }

    @Test func aProjectWithNeitherFileReadsAsNeitherRatherThanFailing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try fixture.store.readDeclaration() == nil)
        #expect(try fixture.store.readLock() == nil)
    }

    @Test func aDeclarationCanBeWrittenBeforeAnythingIsResolved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // What a project wants and what it resolved to are separate steps.
        try fixture.store.write(declaration: try Self.declaration(), lock: nil)

        #expect(try fixture.store.readDeclaration() != nil)
        #expect(try fixture.store.readLock() == nil)
    }

    private static func declaration(reversed: Bool = false) throws -> WorkspaceProjectDeclaration {
        let entries: [WorkspaceProjectDeclaration.Entry] = [
            .init(name: "auditor", kind: .skill, repositoryURL: "https://github.com/you/skills",
                  requestedRef: "main", packageRelativePath: "skills/auditor"),
            .init(name: "reviewer", kind: .skill, repositoryURL: "https://github.com/you/skills",
                  requestedRef: "main", packageRelativePath: "skills/reviewer"),
        ]
        return try .init(entries: reversed ? entries.reversed() : entries)
    }

    private static func lock() throws -> WorkspaceProjectLock {
        try .init(entries: [
            .init(name: "auditor", kind: .skill, repositoryURL: "https://github.com/you/skills",
                  requestedRef: "main",
                  revision: .init(kind: .gitCommitSHA1, value: String(repeating: "a", count: 40)),
                  contentDigest: .init(value: String(repeating: "b", count: 64)),
                  packageRelativePath: "skills/auditor"),
        ])
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceProjectDeclarationStore

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "project-declaration-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            store = try WorkspaceProjectDeclarationStore(projectRoot: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
