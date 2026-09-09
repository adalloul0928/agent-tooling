import Foundation
import Testing

@testable import AgentToolingCore

/// Finding a client's own command-line tool. Only a runnable file counts: the
/// caller's next step is putting the path into a command a person approves, and
/// an approval for something that cannot run is worse than no offer.
@Suite("Client executable locator")
struct ClientExecutableLocatorTests {
    @Test func aRunnableFileInAKnownPlaceIsFound() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installTool(named: "codex", executable: true)

        let found = ClientExecutableLocator.locate(.codex, homeURL: fixture.home)

        #expect(found?.path == fixture.binary(named: "codex").path)
    }

    @Test func aFileThatIsNotRunnableIsNotOffered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installTool(named: "codex", executable: false)

        #expect(ClientExecutableLocator.locate(.codex, homeURL: fixture.home) == nil)
    }

    @Test func aToolThatIsNotThereIsNotGuessedAt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // Returning a plausible path would produce a command a person could
        // approve and that could never run.
        #expect(ClientExecutableLocator.locate(.claude, homeURL: fixture.home) == nil)
    }

    @Test func aLinkIsFollowedAndTheFileItLeadsToIsWhatRuns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let real = fixture.root.appending(path: "elsewhere/codex")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createDirectory(at: fixture.binary(named: "codex").deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.binary(named: "codex"),
                                                   withDestinationURL: real)

        let found = ClientExecutableLocator.locate(.codex, homeURL: fixture.home)

        // The command that runs is the file that was tested, not a link that
        // might point somewhere else by the time it runs.
        #expect(found?.path == real.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func aLinkThatLeadsToSomethingElseEntirelyIsNotThisClientsTool() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = fixture.root.appending(path: "elsewhere/something-else")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        try FileManager.default.createDirectory(at: fixture.binary(named: "codex").deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.binary(named: "codex"),
                                                   withDestinationURL: other)

        #expect(ClientExecutableLocator.locate(.codex, homeURL: fixture.home) == nil)
    }

    @Test func aDirectoryWithTheRightNameIsNotATool() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.binary(named: "codex"),
                                                withIntermediateDirectories: true)

        #expect(ClientExecutableLocator.locate(.codex, homeURL: fixture.home) == nil)
    }

    @Test func everyCandidateIsAnAbsolutePathEndingInTheToolsOwnName() {
        for client in ClientKind.allCases {
            let name = ClientExecutableLocator.executableName(for: client)
            let candidates = ClientExecutableLocator.candidates(
                for: client, homeURL: URL(fileURLWithPath: "/Users/me"))
            #expect(!candidates.isEmpty)
            #expect(candidates.allSatisfy { $0.lastPathComponent == name })
            #expect(candidates.allSatisfy { NativeSkillDestination.isValidRoot($0) })
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "client-locator-\(UUID())")
            home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        /// The first home-relative candidate the locator checks.
        func binary(named name: String) -> URL {
            home.appending(path: ".local/bin").appending(path: name).standardizedFileURL
        }

        func installTool(named name: String, executable: Bool) throws {
            let url = binary(named: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                                  ofItemAtPath: url.path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
