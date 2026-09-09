import Foundation
import Testing

@testable import AgentToolingCore

/// The command a client uses to install its own packages. Recorded with the
/// release it was checked against, never guessed for a client nobody checked.
@Suite("Native plugin install register")
struct NativePluginInstallRegisterTests {
    @Test func eachRecordedClientHasACommandAndSaysWhereItCameFrom() throws {
        for client in [ClientKind.claude, .codex] {
            let command = try #require(
                NativePluginInstallRegister.command(for: client, externalPluginID: "browser"))
            #expect(command.executable == (client == .claude ? "claude" : "codex"))
            #expect(command.installArguments.contains("browser"))
            #expect(!command.removeArguments.isEmpty)
            // A recorded fact that cannot be rechecked is a guess with a date on
            // it, so both the release and the source are required.
            #expect(!command.verifiedAgainstVersion.isEmpty)
            #expect(!command.source.isEmpty)
        }
    }

    @Test func aClientNobodyCheckedGetsNoCommandRatherThanAPlausibleOne() {
        // Writing something that looks right for Gemini is exactly the
        // invention this register exists to avoid.
        #expect(NativePluginInstallRegister.command(for: .gemini, externalPluginID: "browser") == nil)
        #expect(NativePluginInstallRegister.reviewedInstall(for: .gemini, externalPluginID: "browser") == nil)
    }

    @Test func theRecordedCommandsMatchWhatTheClientsActuallyTake() throws {
        // Read from each installed tool's own help output rather than a page
        // that may describe a different release.
        let claude = try #require(
            NativePluginInstallRegister.command(for: .claude, externalPluginID: "browser"))
        #expect(claude.installArguments == ["plugin", "install", "browser", "--scope", "user"])
        #expect(claude.removeArguments == ["plugin", "uninstall", "browser"])

        let codex = try #require(
            NativePluginInstallRegister.command(for: .codex, externalPluginID: "browser"))
        #expect(codex.installArguments == ["plugin", "add", "browser"])
        #expect(codex.removeArguments == ["plugin", "remove", "browser"])
    }

    @Test func anIdentifierThisAppWouldNotRunIsRefusedBeforeACommandIsBuilt() {
        // The identifier becomes an argument, so anything that could be read as
        // a flag or a path never reaches one.
        for identifier in ["--force", "../escape", "with space", "", "a;b"] {
            #expect(NativePluginInstallRegister.command(
                for: .codex, externalPluginID: identifier) == nil, "'\(identifier)' produced a command")
        }
    }

    @Test func theCommandPolicyAcceptsEveryCommandTheRegisterProduces() throws {
        // The register and the executor's policy must agree, or a recorded
        // command would be offered and then refused at the moment of running.
        let policy = OperationCommandPolicy(libraryURL: URL(fileURLWithPath: "/"),
                                            gitBackupRoot: URL(fileURLWithPath: "/"))
        for client in [ClientKind.claude, .codex] {
            let command = try #require(
                NativePluginInstallRegister.command(for: client, externalPluginID: "browser"))
            #expect(throws: Never.self) {
                try policy.validate(executable: command.executable, arguments: command.installArguments)
            }
        }
    }

    @Test func theReviewedInstallIsTheSameCommandInTheShapeTheBridgeChecks() throws {
        let install = try #require(
            NativePluginInstallRegister.reviewedInstall(for: .codex, externalPluginID: "browser"))
        let command = try #require(
            NativePluginInstallRegister.command(for: .codex, externalPluginID: "browser"))

        #expect(install.executable == command.executable)
        #expect(install.arguments == command.installArguments)
        #expect(install.removalArguments == command.removeArguments)
        #expect(install.scope == .user)
    }
}
