import Foundation
import Testing

@testable import AgentToolingCore

/// Which clients this Mac shows: an explicit choice wins, and without one the
/// scan decides, so an app that is not installed stays out of the way.
struct ClientVisibilityPolicyTests {
    private func observation(_ surface: TargetSurface, installed: Bool, commandAvailable: Bool) -> TargetObservation {
        .init(
            surface: surface, installed: installed, commandAvailable: commandAvailable, version: nil,
            capabilities: .init(
                supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                requiresRestart: false, supportsMachineReadableOutput: false),
            lastScannedAt: .now)
    }

    @Test func anExplicitChoiceWinsOverEverything() {
        let preferences = DeviceWorkspacePreferences(chosenClients: [.gemini])
        let observed = [observation(.claudeCode, installed: true, commandAvailable: true)]

        #expect(
            ClientVisibilityPolicy.effectiveEnabledClients(preferences: preferences, observations: observed)
                == [.gemini])
    }

    /// A pre-choice build persisted `enabledClients` as a default-of-all with
    /// three cases. After a fourth client ships, that stale default must not
    /// read as somebody deliberately excluding the newcomer.
    @Test func anOlderBuildsLegacyFieldIsNotMistakenForAChoice() {
        let preferences = DeviceWorkspacePreferences(enabledClients: [.claude, .codex, .gemini])
        let observed = [observation(.kiroCLI, installed: true, commandAvailable: true)]

        #expect(
            ClientVisibilityPolicy.effectiveEnabledClients(preferences: preferences, observations: observed)
                == [.kiro])
        #expect(
            ClientVisibilityPolicy.effectiveEnabledClients(preferences: preferences, observations: [])
                == Set(ClientKind.allCases))
    }

    @Test func withNoChoiceOnlyClientsWhoseToolActuallyRunsAreShown() {
        let observed = [
            observation(.claudeCode, installed: true, commandAvailable: true),
            observation(.codexCLI, installed: false, commandAvailable: true),
            observation(.geminiCLI, installed: false, commandAvailable: false),
            // Leftover files are not a setup: the tool itself cannot be run.
            observation(.kiroCLI, installed: true, commandAvailable: false),
        ]

        #expect(
            ClientVisibilityPolicy.effectiveEnabledClients(preferences: nil, observations: observed)
                == [.claude, .codex])
    }

    @Test func beforeAnyScanEveryClientIsShown() {
        #expect(
            ClientVisibilityPolicy.effectiveEnabledClients(preferences: nil, observations: [])
                == Set(ClientKind.allCases))
    }

    @Test func aScanThatFoundNothingStillShowsEverythingToSetUp() {
        let observed = [observation(.claudeCode, installed: true, commandAvailable: false)]

        #expect(
            ClientVisibilityPolicy.effectiveEnabledClients(preferences: nil, observations: observed)
                == Set(ClientKind.allCases))
    }
}

/// Finding a tool the deterministic way: the login shell's own answer, checked
/// before it is believed.
struct SmartToolFinderTests {
    private struct ScriptedRunner: CommandRunning {
        let answers: [String: CommandOutput]

        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            #expect(executable == "/bin/zsh")
            #expect(arguments.count == 2 && arguments[0] == "-l" || arguments.count == 3)
            let command = arguments.last ?? ""
            return answers[command] ?? CommandOutput(status: 1, standardOutput: "", standardError: "")
        }
    }

    @Test func theLoginShellsAnswerIsAcceptedOnlyWhenItIsARunnableToolOfTheRightName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "smart-find-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "shims", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let runner = ScriptedRunner(answers: [
            "command -v codex": CommandOutput(status: 0, standardOutput: codex.path + "\n", standardError: ""),
            // A relative answer, a missing file, and a wrong name are refused.
            "command -v claude": CommandOutput(status: 0, standardOutput: "claude\n", standardError: ""),
            "command -v gemini": CommandOutput(
                status: 0, standardOutput: root.appending(path: "missing/gemini").path, standardError: ""),
            "command -v kiro-cli": CommandOutput(status: 0, standardOutput: codex.path, standardError: ""),
        ])

        let findings = await SmartToolFinder.probe(clients: ClientKind.allCases, runner: runner)

        #expect(findings.map(\.client) == [.codex])
        #expect(findings.first?.executableURL.path == codex.path)
        #expect(findings.first?.directory.path == bin.path)
    }

    @Test func aShellThatDoesNotKnowTheToolProducesNoFinding() async {
        let runner = ScriptedRunner(answers: [:])

        let findings = await SmartToolFinder.probe(clients: [.codex], runner: runner)

        #expect(findings.isEmpty)
    }
}
