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

        let found = fixture.locate(.codex)

        #expect(found?.path == fixture.binary(named: "codex").path)
    }

    @Test func aFileThatIsNotRunnableIsNotOffered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installTool(named: "codex", executable: false)

        #expect(fixture.locate(.codex) == nil)
    }

    @Test func aToolThatIsNotThereIsNotGuessedAt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // Returning a plausible path would produce a command a person could
        // approve and that could never run.
        #expect(fixture.locate(.claude) == nil)
    }

    @Test func aLinkIsTestedAtWhatItLeadsToAndOfferedByItsOwnName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let real = fixture.root.appending(path: "elsewhere/codex")
        try fixture.installRunnableFile(at: real)
        try fixture.link(named: "codex", to: real)

        let found = fixture.locate(.codex)

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

        let found = fixture.locate(.claude)

        #expect(found?.path == fixture.binary(named: "claude").path)
    }

    /// Amazon Toolbox installs internal builds as `~/.toolbox/bin/<tool>`
    /// symlinks to one shared dispatcher. The shim is the tool's own path and
    /// the dispatcher is what has to be runnable.
    @Test func aToolboxShimIsFoundAndOfferedByItsOwnName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let dispatcher = fixture.home.appending(path: ".toolbox/tools/toolbox/1.1.0/toolbox-exec")
        try fixture.installRunnableFile(at: dispatcher)
        let shim = fixture.home.appending(path: ".toolbox/bin/codex")
        try FileManager.default.createDirectory(
            at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: dispatcher)

        let found = fixture.locate(.codex)

        #expect(found?.path == shim.path)
    }

    /// A Mac with Toolbox usually also has an older native install beside it.
    /// The managed shim is the one the person's shell runs and the one that
    /// carries their sign-in, so it is the one offered.
    @Test func aToolboxShimIsPreferredToANativeInstallBesideIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installTool(named: "claude", executable: true)
        let dispatcher = fixture.home.appending(path: ".toolbox/tools/toolbox/1.1.0/toolbox-exec")
        try fixture.installRunnableFile(at: dispatcher)
        let shim = fixture.home.appending(path: ".toolbox/bin/claude")
        try FileManager.default.createDirectory(
            at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: dispatcher)

        #expect(fixture.locate(.claude)?.path == shim.path)
    }

    /// Every folder a child process searches is checked, so a tool a child
    /// could start by name, here one installed through Volta, is offered by
    /// its own path rather than missed.
    @Test func aToolInAnyFolderAChildSearchesIsFound() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let volta = fixture.home.appending(path: ".volta/bin/codex")
        try fixture.installRunnableFile(at: volta)

        #expect(fixture.locate(.codex)?.path == volta.path)
    }

    /// The folders the locator always checked still come first, so the tool
    /// it found before is the one it finds now, even where a child's own
    /// search order would reach another copy first.
    @Test func aFolderTheLocatorAlwaysCheckedStillWins() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let npm = fixture.home.appending(path: ".npm-global/bin/codex")
        try fixture.installRunnableFile(at: npm)
        try fixture.installRunnableFile(at: fixture.home.appending(path: ".cargo/bin/codex"))

        #expect(fixture.locate(.codex)?.path == npm.path)
    }

    @Test func aLinkToSomethingThatCannotRunIsNotOffered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plain = fixture.root.appending(path: "elsewhere/codex")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not a program\n".utf8).write(to: plain)
        try fixture.link(named: "codex", to: plain)

        #expect(fixture.locate(.codex) == nil)
    }

    @Test func aDanglingLinkIsNotOffered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.link(named: "codex", to: fixture.root.appending(path: "elsewhere/gone"))

        #expect(fixture.locate(.codex) == nil)
    }

    @Test func aDirectoryWithTheRightNameIsNotATool() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.binary(named: "codex"),
                                                withIntermediateDirectories: true)

        #expect(fixture.locate(.codex) == nil)
    }

    /// The fixtures look only in their own folders, so what this Mac has
    /// installed cannot change their answers. The app's own order is untouched:
    /// the folders every process shares are still checked first.
    @Test func theFoldersEveryProcessSharesAreStillCheckedFirst() {
        let roots = ClientExecutableLocator.fixedRoots(homeURL: URL(fileURLWithPath: "/Users/me", isDirectory: true))

        #expect(
            roots.prefix(6).map(\.path) == [
                "/opt/homebrew/bin", "/usr/local/bin", "/Users/me/.toolbox/bin", "/Users/me/.local/bin",
                "/Users/me/.bun/bin", "/Users/me/.npm-global/bin",
            ])
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

        /// Whether a folder is this fixture's own.
        func owns(_ folder: URL) -> Bool {
            folder.standardizedFileURL.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false) + "/")
        }

        /// The locator, looking only in this fixture's folders. The fixed
        /// roots start with folders every process on the Mac shares, such as
        /// /opt/homebrew/bin, and a tool installed there on the Mac running
        /// the tests would be found before anything in the fixture's home.
        func locate(_ client: ClientKind) -> URL? {
            ClientExecutableLocator.locate(client, homeURL: home, searching: owns)
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
