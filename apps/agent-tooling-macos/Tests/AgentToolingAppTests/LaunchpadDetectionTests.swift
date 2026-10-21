import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Your apps' detection (S02, V01): the tools found without running
/// anything, the choice, the two ways to look again, the one rule that
/// allows no app at all, and the rerun's toggles, which write this Mac's
/// record at once.
@Suite("Launchpad detection", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadDetectionTests {
    @Test func detectionFindsJunipersToolsAndRunsNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let runners = RunnerLog()
        var environment = fixture.environment
        environment.makeRunner = { _ in runners.made() }

        let detection = LaunchpadDetection(environment: environment)
        detection.lookAgain()

        #expect(detection.found == [.codex, .claude, .gemini])
        #expect(detection.notFound == [.kiro])
        #expect(!detection.isEmptyMac)
        #expect(detection.chosen == [.codex, .claude, .gemini])
        #expect(detection.app(.claude).executable == fixture.world.tools[.claude])
        #expect(detection.displayPath(.claude) == "~/.local/bin/claude")
        #expect(detection.displayPath(.kiro) == nil)
        // Looking is reading the folders: no command, no read, no sign-in.
        #expect(runners.count == 0)
        #expect(fixture.firstReads.started.isEmpty)
        #expect(fixture.signIn.shellProbes == 0)
    }

    /// ⌘R: a tool installed since lights where it sits and is chosen; one
    /// turned off stays off.
    @Test func lookingAgainFindsAToolInstalledSince() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let detection = LaunchpadDetection(environment: fixture.environment)
        detection.toggle(.codex)
        #expect(detection.chosen == [.claude, .gemini])

        try fixture.world.home.installTool(.kiro, in: ".npm-global/bin")
        detection.lookAgain()

        #expect(detection.found == [.codex, .claude, .gemini, .kiro])
        #expect(detection.chosen == [.claude, .gemini, .kiro])
    }

    /// ⌘L: the login shell knows a folder the locator does not check. The
    /// folder is held, handed to the process's lookups through the injected
    /// closure (never the process-wide list itself), carried in the seed,
    /// and the tool lights. Only the missing app's shell lookup ran.
    @Test func theLoginShellsFolderIsHeldAndRegisteredThroughTheEnvironment() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let tool = try fixture.world.home.installTool(.kiro, in: "tools/kiro/bin")
        let folder = LaunchpadDetection.folderPath(tool.deletingLastPathComponent())
        let registered = RegisteredRoots()
        let runner = ScriptedCommandRunner(byTool: [
            "zsh": [["-l", "-c", "command -v kiro-cli"]: .standardOutput(tool.path(percentEncoded: false) + "\n")]
        ])
        var environment = fixture.environment
        environment.makeRunner = { _ in runner }
        environment.registerToolRoots = { registered.record($0) }
        let world = fixture.world
        environment.locate = { client, _ in world.locate(client) ?? registered.locate(client) }

        let detection = LaunchpadDetection(environment: environment)
        #expect(detection.notFound == [.kiro])
        await detection.lookAgainWithLoginShell()

        #expect(await runner.launches.map(\.display) == ["zsh -l -c command -v kiro-cli"])
        #expect(registered.calls == [[folder]])
        #expect(detection.toolDirectories == [folder])
        #expect(detection.app(.kiro).executable == tool)
        #expect(detection.chosen.contains(.kiro))
        #expect(detection.seed(findsProjectsFromClaudeHistory: true).toolDirectories == [folder])
        #expect(detection.loginShellMessage == "Your login shell found Kiro CLI.")
        #expect(!detection.isAskingLoginShell)
    }

    /// A rerun's registration keeps the folders this Mac's record already
    /// holds, because registering replaces the process's whole list.
    @Test func aRegistrationKeepsTheFoldersAlreadyRecorded() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let tool = try fixture.world.home.installTool(.kiro, in: "tools/kiro/bin")
        let folder = LaunchpadDetection.folderPath(tool.deletingLastPathComponent())
        let registered = RegisteredRoots()
        let runner = ScriptedCommandRunner(byTool: [
            "zsh": [["-l", "-c", "command -v kiro-cli"]: .standardOutput(tool.path(percentEncoded: false) + "\n")]
        ])
        var environment = fixture.environment
        environment.makeRunner = { _ in runner }
        environment.registerToolRoots = { registered.record($0) }

        let detection = LaunchpadDetection(environment: environment, recordedToolDirectories: ["/opt/recorded/bin"])
        await detection.lookAgainWithLoginShell()

        #expect(registered.calls == [["/opt/recorded/bin", folder].sorted()])
        #expect(detection.toolDirectories == [folder])
    }

    /// A login shell that knows nothing more says so, and nothing is held
    /// or registered.
    @Test func aLoginShellThatKnowsNothingMoreSaysSo() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let registered = RegisteredRoots()
        var environment = fixture.environment
        environment.registerToolRoots = { registered.record($0) }
        let detection = LaunchpadDetection(environment: environment)

        await detection.lookAgainWithLoginShell()

        #expect(registered.calls.isEmpty)
        #expect(detection.toolDirectories.isEmpty)
        #expect(detection.loginShellMessage == "Your login shell does not know Kiro CLI either.")
        #expect(detection.found == [.codex, .claude, .gemini])
    }

    /// Nothing missing, nothing to ask: no shell runs.
    @Test func withEveryAppFoundTheLoginShellIsNotAsked() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        try fixture.world.home.installTool(.kiro, in: ".npm-global/bin")
        let runners = RunnerLog()
        var environment = fixture.environment
        environment.makeRunner = { _ in runners.made() }
        let detection = LaunchpadDetection(environment: environment)

        await detection.lookAgainWithLoginShell()

        #expect(runners.count == 0)
        #expect(detection.loginShellMessage == nil)
    }

    /// V01: on a Mac with none of the apps the screen is the empty Mac's and
    /// its primary creates the library with no app, reading nothing.
    @Test func noAppIsAChoiceToo() async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        let detection = LaunchpadDetection.of(flow)

        #expect(detection.isEmptyMac)
        #expect(detection.chosen.isEmpty)
        #expect(LaunchpadTileSequenceScreen.title(.apps, detection: detection) == "No apps found on this Mac yet")
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Continue without apps")
        primary.action()
        await waitUntil { flow.step == .library }

        #expect(flow.seedOverride?.chosen == [])
        #expect(fixture.hasWorkspace)
        #expect(fixture.firstReads.started.isEmpty)
        #expect(fixture.signIn.shellProbes == 0)
        #expect(flow.workspace?.device.managedClients == [])
        #expect(flow.outcomes.read?.notFound == ClientKind.allCases)
    }

    /// The primary counts what will be managed: an app turned off is
    /// dropped, one turned on while missing is added, none reads Continue
    /// without apps.
    @Test func thePrimaryCountsTheChoice() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        let detection = LaunchpadDetection.of(flow)
        func title() -> String? { LaunchpadStageView.footer(for: flow).primary?.title }

        #expect(title() == "Manage 3 apps")
        detection.toggle(.kiro)
        #expect(title() == "Manage 4 apps")
        for client in ClientKind.allCases { detection.toggle(client) }
        #expect(title() == "Continue without apps")
        detection.toggle(.claude)
        #expect(title() == "Manage 1 app")
    }

    /// Continue hands the walk the choice, with the projects choice as it
    /// stands.
    @Test func continueHandsTheChoiceToTheWalk() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadDetection.of(flow).toggle(.gemini)

        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.step == .reads)
        #expect(flow.seedOverride == LaunchpadSeed(chosen: [.codex, .claude]))
        // Back keeps it.
        flow.goBack()
        #expect(flow.step == .apps)
        #expect(LaunchpadDetection.of(flow).chosen == [.codex, .claude])
    }

    /// On a rerun the library exists: a tile (its click, its ⌘ key or
    /// Space) writes this Mac's record at once, and two presses are two
    /// flips. The primary only moves on, handing the walk this Mac's choice
    /// as it stands.
    @Test func aRerunsTilesWriteThisMacsRecord() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let flow = fixture.flow(.rerun, workspace: workspace)
        #expect(flow.info.back == nil)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Manage 3 apps")
        func recorded() throws -> Set<ClientKind>? {
            try workspace.store.snapshot()?.device.applicationState?.preferences.chosenClients.map(Set.init)
        }

        await LaunchpadTileSequenceScreen.toggle(.gemini, flow: flow)?.value
        #expect(workspace.device.managedClients == [.codex, .claude])
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Manage 2 apps")
        #expect(try recorded() == [.codex, .claude])

        let off = LaunchpadTileSequenceScreen.toggle(.kiro, flow: flow)
        let on = LaunchpadTileSequenceScreen.toggle(.kiro, flow: flow)
        await off?.value
        await on?.value
        #expect(workspace.device.managedClients == [.codex, .claude])
        #expect(try recorded() == [.codex, .claude])

        LaunchpadStageView.footer(for: flow).primary?.action()
        #expect(flow.step == .reads)
        #expect(flow.seedOverride == LaunchpadSeed(chosen: [.codex, .claude]))
    }

    /// On a first run a tile is the walk's choice: the seed changes and
    /// nothing is written anywhere.
    @Test func aFirstRunsTilesChangeOnlyTheWalksChoice() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.support.path(percentEncoded: false))

        #expect(LaunchpadTileSequenceScreen.toggle(.codex, flow: flow) == nil)
        #expect(LaunchpadDetection.of(flow).chosen == [.claude, .gemini])
        #expect(flow.seedOverride == LaunchpadSeed(chosen: [.claude, .gemini]))
        LaunchpadTileSequenceScreen.toggle(.kiro, flow: flow)
        #expect(flow.seedOverride?.chosen == [.claude, .gemini, .kiro])

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.support.path(percentEncoded: false)) == before)
        #expect(!fixture.hasWorkspace)
        #expect(flow.workspace == nil)
    }

    /// A rerun's ⌘L: the folder the login shell finds joins the ones this
    /// Mac's record holds, and Continue hands both to the walk, where the
    /// stage audit looks in them.
    @Test func aRerunsLoginShellFolderReachesTheStageAudit() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        // A library whose record already holds a folder of its own.
        let first = fixture.flow()
        first.choosePath(.startHere)
        LaunchpadStageView.footer(for: first).primary?.action()
        first.seedOverride?.toolDirectories = ["/opt/recorded/bin"]
        let read = LaunchpadReadSession.of(first)
        LaunchpadStageView.footer(for: first).primary?.action()
        await waitUntil { read.phase == .finished }
        let workspace = try #require(first.workspace)
        let tool = try fixture.world.home.installTool(.kiro, in: "tools/kiro/bin")
        let folder = LaunchpadDetection.folderPath(tool.deletingLastPathComponent())
        let registered = RegisteredRoots()
        let runner = ScriptedCommandRunner(byTool: [
            "zsh": [["-l", "-c", "command -v kiro-cli"]: .standardOutput(tool.path(percentEncoded: false) + "\n")]
        ])
        var environment = fixture.environment
        environment.makeRunner = { _ in runner }
        environment.registerToolRoots = { registered.record($0) }

        let flow = LaunchpadFlow(entry: .rerun, environment: environment, workspace: workspace)
        await LaunchpadDetection.of(flow).lookAgainWithLoginShell()
        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.step == .reads)
        #expect(registered.calls == [["/opt/recorded/bin", folder].sorted()])
        #expect(flow.seedOverride?.toolDirectories == ["/opt/recorded/bin", folder].sorted())
        #expect(flow.seedOverride?.chosen == [.codex, .claude, .gemini])
        #expect(flow.seedOverride?.findsProjectsFromClaudeHistory == true)
    }

    // MARK: - Tables

    /// Every app has its vendor's own install page.
    @Test func everyAppHasItsInstallPage() {
        let pages = ClientKind.allCases.map(LaunchpadDetection.installPage(for:)).map(\.absoluteString)
        #expect(
            pages == [
                "https://learn.chatgpt.com/docs/codex/cli", "https://code.claude.com/docs/en/setup",
                "https://geminicli.com/docs/get-started/installation/", "https://kiro.dev/docs/cli/",
            ])
    }

    /// "Where Agent Tooling looked" is the locator's own folders, in the
    /// order it checks them, the system folders and the shims said once.
    @Test func whereItLookedIsTheLocatorsOwnFolders() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let looked = LaunchpadDetection.lookedIn(for: .kiro, homeURL: home)
        // The fixed folders, after any this process has registered.
        #expect(
            looked.hasSuffix(
                "/opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.bun/bin, ~/.npm-global/bin, ~/.cargo/bin, ~/.volta/bin, ~/Library/pnpm, the system folders, mise and asdf shims, ~/bin."
            ), "\(looked)")
    }
}

/// Counts the runners a detection asks for, and hands back one that refuses.
private final class RunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0

    var count: Int { lock.withLock { creations } }

    func made() -> any CommandRunning {
        lock.withLock { creations += 1 }
        return RefusingCommandRunner()
    }
}

/// What a detection registered for every lookup, and a lookup that honours
/// it, standing in for the process-wide list.
private final class RegisteredRoots: @unchecked Sendable {
    private let lock = NSLock()
    private var registered: [[String]] = []

    var calls: [[String]] { lock.withLock { registered } }

    func record(_ folders: [String]) {
        lock.withLock { registered.append(folders) }
    }

    func locate(_ client: ClientKind) -> URL? {
        let name = ClientExecutableLocator.executableName(for: client)
        for folder in calls.last ?? [] {
            let tool = URL(filePath: folder, directoryHint: .isDirectory).appending(path: name).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: tool.path(percentEncoded: false)) { return tool }
        }
        return nil
    }
}
