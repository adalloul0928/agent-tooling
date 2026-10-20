import Foundation
import Testing

@testable import AgentToolingCore

/// Opening a client in Terminal with one skill invoked. The launcher writes a
/// script and nothing else: every value in it is quoted, the tool is the one
/// the locator found, and the argument list has passed the operation policy.
@Suite("Skill trial launch")
struct SkillTrialLaunchTests {
    @Test func eachClientIsCalledTheWayItsOwnChatWould() {
        #expect(SkillTrialCommandShapes.arguments(for: .claude, skillName: "release-review") == ["/release-review"])
        #expect(
            SkillTrialCommandShapes.arguments(for: .claude, skillName: "skill-creator:skill-creator")
                == ["/skill-creator:skill-creator"])
        #expect(SkillTrialCommandShapes.arguments(for: .codex, skillName: "release-review") == ["$release-review"])
        // Codex and Kiro do not namespace a plugin's skill; the bare name is
        // what they answer to.
        #expect(SkillTrialCommandShapes.arguments(for: .codex, skillName: "my-plugin:release-review") == ["$release-review"])
        #expect(SkillTrialCommandShapes.arguments(for: .kiro, skillName: "release-review") == ["chat", "/release-review"])
        #expect(SkillTrialCommandShapes.arguments(for: .gemini, skillName: "release-review") == nil)
        #expect(!SkillTrialCommandShapes.isSupported(.gemini))
    }

    @Test(arguments: ["", "-p", "--resume", "a b", "../x", "name;rm", "a:b:c", ":name", "name:", "$(id)", "é"])
    func aNameThatIsNotOneIdentifierIsRefused(name: String) {
        #expect(!SkillTrialCommandShapes.isValidSkillReference(name))
        #expect(SkillTrialCommandShapes.arguments(for: .claude, skillName: name) == nil)
    }

    @Test func thePolicyAdmitsExactlyTheTrialShapesAndNothingNear() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let policy = OperationCommandPolicy(
            libraryURL: home.appending(path: "library"), gitBackupRoot: home.appending(path: "backup"), homeURL: home)

        #expect(throws: Never.self) {
            try policy.validate(executable: "claude", arguments: ["/release-review"])
            try policy.validate(executable: "claude", arguments: ["/skill-creator:skill-creator"])
            try policy.validate(executable: "codex", arguments: ["$release-review"])
            try policy.validate(executable: "kiro-cli", arguments: ["chat", "/release-review"])
        }
        // A flag where the invocation goes, a second word, the wrong sigil for
        // the client, a path: each is one token off and each is refused.
        #expect(throws: OperationEngineError.self) {
            try policy.validate(executable: "claude", arguments: ["--dangerously-skip-permissions"])
        }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: ["/release-review", "extra"]) }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: ["$release-review"]) }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "codex", arguments: ["/release-review"]) }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "kiro-cli", arguments: ["/release-review"]) }
        #expect(throws: OperationEngineError.self) {
            try policy.validate(executable: "kiro-cli", arguments: ["chat", "-a", "/release-review"])
        }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: ["/../etc/passwd"]) }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "gemini", arguments: ["/release-review"]) }
    }

    @Test func theScriptQuotesEveryValueAndRunsThroughThePersonsShell() {
        let body = TerminalCommandScript.render(
            title: "Try it",
            workingDirectory: URL(filePath: "/Users/ex ample/it's here", directoryHint: .isDirectory),
            executable: "/Users/ex ample/.local/bin/claude",
            arguments: ["/release-review"])

        #expect(body.hasPrefix("#!/bin/zsh\n"))
        #expect(body.contains("cd '/Users/ex ample/it'\\''s here' || exit 1"))
        // The inner command is one quoted word to the login shell, and inside
        // it every part is quoted again.
        #expect(
            body.contains(
                "exec \"${SHELL:-/bin/zsh}\" -l -i -c 'exec '\\''/Users/ex ample/.local/bin/claude'\\'' '\\''/release-review'\\'''"))
        #expect(!body.contains("\n\n\n"))

        let direct = TerminalCommandScript.render(
            title: "Try it", workingDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory),
            executable: "/bin/echo", arguments: ["$name"], interactiveShell: false)
        #expect(direct.contains("exec '/bin/echo' '$name'"))
    }

    @Test func shellQuotingSurvivesEveryAwkwardCharacter() async throws {
        let awkward = "it's $HOME `id` \"x\" \\ ; & | > < * ? [a] {b} ~ !"
        let body = TerminalCommandScript.render(
            title: "Quote check", workingDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory),
            executable: "/bin/echo", arguments: [awkward], interactiveShell: false)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SkillTrialLaunchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try TerminalCommandScript.write(body, named: "quote-check", in: root)

        // Only a hang should run out of this time: at the start of a parallel
        // run, a command that ends at once can wait seconds for its task to
        // resume.
        let output = try await ProcessCommandRunner(timeout: .seconds(30)).run(
            executable: script.path(percentEncoded: false), arguments: [], currentDirectory: nil)

        #expect(output.status == 0)
        #expect(output.standardOutput == awkward + "\n")
    }

    @Test func theLauncherWritesAPrivateScriptForTheLocatedTool() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SkillTrialLaunchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let tool = home.appending(path: ".local/bin/codex", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        let scripts = root.appending(path: "scripts", directoryHint: .isDirectory)
        let launcher = SkillTrialLauncher(homeURL: home, scriptsDirectory: scripts)

        let launch = try launcher.prepare(client: .codex, skillName: "release-review")

        #expect(launch.executable == tool.path(percentEncoded: false))
        #expect(launch.arguments == ["$release-review"])
        #expect(launch.commandLine == "codex $release-review")
        #expect(launch.scriptURL.lastPathComponent == "try-codex-release-review.command")
        let permissions =
            try FileManager.default.attributesOfItem(atPath: launch.scriptURL.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        let body = try String(contentsOf: launch.scriptURL, encoding: .utf8)
        #expect(body.contains("'\\''\(tool.path(percentEncoded: false))'\\''"))
        let homePath = "/" + home.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        #expect(body.contains("cd '\(homePath)' || exit 1"))

        // Preparing again replaces the file rather than piling up copies.
        _ = try launcher.prepare(client: .codex, skillName: "release-review")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scripts.path(percentEncoded: false)).count == 1)
    }

    @Test func nothingIsWrittenWhenTheToolIsMissingOrTheClientUnsupported() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SkillTrialLaunchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let scripts = root.appending(path: "scripts", directoryHint: .isDirectory)
        let launcher = SkillTrialLauncher(homeURL: home, scriptsDirectory: scripts)

        #expect(throws: SkillTrialLaunchError.toolNotFound(.claude)) {
            try launcher.prepare(client: .claude, skillName: "release-review")
        }
        #expect(throws: SkillTrialLaunchError.unsupportedClient(.gemini)) {
            try launcher.prepare(client: .gemini, skillName: "release-review")
        }
        #expect(throws: SkillTrialLaunchError.invalidSkillName("not a name")) {
            try launcher.prepare(client: .claude, skillName: "not a name")
        }
        #expect(!FileManager.default.fileExists(atPath: scripts.path(percentEncoded: false)))
    }

    @Test func aScriptIsNotWrittenThroughALink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SkillTrialLaunchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "real", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linked = root.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

        #expect(throws: TerminalCommandScriptError.self) {
            try TerminalCommandScript.write("#!/bin/zsh\n", named: "x", in: linked)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path(percentEncoded: false)).isEmpty)
    }
}
