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

    @Test func aLinkIsTestedAtWhatItLeadsToAndOfferedByItsOwnName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let real = fixture.root.appending(path: "elsewhere/codex")
        try fixture.installRunnableFile(at: real)
        try fixture.link(named: "codex", to: real)

        let found = ClientExecutableLocator.locate(.codex, homeURL: fixture.home)

        // What was tested is the file the link leads to; what is offered is the
        // link, which is the path a person recognises and the name every
        // command check looks for. Launching follows the link again.
        #expect(found?.path == fixture.binary(named: "codex").path)
    }

    /// Claude Code's installer keeps the binary under a version number and
    /// points `~/.local/bin/claude` at it. Insisting the file behind the link
    /// carry the tool's name refused the real installation on every Mac that
    /// used the installer.
    @Test func aLinkToAVersionNamedFileIsStillThisClientsTool() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let versioned = fixture.home.appending(path: ".local/share/claude/versions/2.1.268")
        try fixture.installRunnableFile(at: versioned)
        try fixture.link(named: "claude", to: versioned)

        let found = ClientExecutableLocator.locate(.claude, homeURL: fixture.home)

        #expect(found?.path == fixture.binary(named: "claude").path)
    }

    @Test func aLinkToSomethingThatCannotRunIsNotOffered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plain = fixture.root.appending(path: "elsewhere/codex")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not a program\n".utf8).write(to: plain)
        try fixture.link(named: "codex", to: plain)

        #expect(ClientExecutableLocator.locate(.codex, homeURL: fixture.home) == nil)
    }

    @Test func aDanglingLinkIsNotOffered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.link(named: "codex", to: fixture.root.appending(path: "elsewhere/gone"))

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

        /// A runnable file at any path, for a link to lead to.
        func installRunnableFile(at url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        /// The candidate by the tool's own name, as a link to `destination`.
        func link(named name: String, to destination: URL) throws {
            let url = binary(named: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
