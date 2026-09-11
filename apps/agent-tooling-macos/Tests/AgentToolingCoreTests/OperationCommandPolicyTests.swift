import Foundation
import Testing

@testable import AgentToolingCore

/// The executor's allowlist and the plan's command must agree about the
/// executable. Plans carry the path the locator found, so an app launched
/// outside a login shell still reaches the tool; the policy accepts exactly
/// that path and nothing else, or every native install is refused at the
/// moment of running.
@Suite("Operation command policy")
struct OperationCommandPolicyTests {
    @Test func aBareNameIsStillAccepted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: Never.self) {
            try fixture.policy.validate(executable: "codex", arguments: ["plugin", "add", "browser@openai"])
        }
    }

    @Test func theToolAtThePlaceTheLocatorFoundItIsAccepted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installTool(named: "codex")
        let located = try #require(ClientExecutableLocator.locate(.codex, homeURL: fixture.home))

        #expect(throws: Never.self) {
            try fixture.policy.validate(executable: located.path, arguments: ["plugin", "add", "browser@openai"])
        }
    }

    /// The two real layouts: Codex inside the ChatGPT app bundle behind a link,
    /// and Claude Code's installer keeping the binary under a version number.
    @Test func aToolReachedThroughALinkIsAcceptedByTheLinksPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installRunnableFile(at: fixture.root.appending(path: "ChatGPT.app/Contents/Resources/codex"))
        try fixture.link(named: "codex", to: fixture.root.appending(path: "ChatGPT.app/Contents/Resources/codex"))
        try fixture.installRunnableFile(at: fixture.home.appending(path: ".local/share/claude/versions/2.1.268"))
        try fixture.link(named: "claude", to: fixture.home.appending(path: ".local/share/claude/versions/2.1.268"))

        #expect(throws: Never.self) {
            try fixture.policy.validate(
                executable: fixture.binary(named: "codex").path, arguments: ["plugin", "add", "browser@openai"])
        }
        #expect(throws: Never.self) {
            try fixture.policy.validate(
                executable: fixture.binary(named: "claude").path,
                arguments: ["plugin", "install", "browser@vendor", "--scope", "user"])
        }
    }

    @Test func aFileWithATheToolsNameSomewhereElseIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installTool(named: "codex")
        let elsewhere = fixture.root.appending(path: "elsewhere/codex")
        try fixture.installRunnableFile(at: elsewhere)

        #expect(throws: OperationEngineError.self) {
            try fixture.policy.validate(executable: elsewhere.path, arguments: ["plugin", "add", "browser@openai"])
        }
    }

    @Test func anAbsolutePathToAnythingElseIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for executable in ["/bin/sh", "/usr/bin/env", "/usr/bin/git", fixture.root.appending(path: "codex").path] {
            #expect(throws: OperationEngineError.self, "\(executable) was accepted") {
                try fixture.policy.validate(executable: executable, arguments: [])
            }
        }
    }

    @Test func theArgumentsAreStillCheckedUnderTheToolsName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installTool(named: "codex")
        let located = try #require(ClientExecutableLocator.locate(.codex, homeURL: fixture.home))

        #expect(throws: OperationEngineError.self) {
            try fixture.policy.validate(executable: located.path, arguments: ["plugin", "add", "--force"])
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let policy: OperationCommandPolicy

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "command-policy-\(UUID())", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            policy = OperationCommandPolicy(
                libraryURL: root.appending(path: "library", directoryHint: .isDirectory),
                gitBackupRoot: root.appending(path: "backup", directoryHint: .isDirectory),
                homeURL: home)
        }

        func binary(named name: String) -> URL {
            home.appending(path: ".local/bin").appending(path: name).standardizedFileURL
        }

        func installTool(named name: String) throws {
            try installRunnableFile(at: binary(named: name))
        }

        func installRunnableFile(at url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func link(named name: String, to destination: URL) throws {
            let url = binary(named: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
