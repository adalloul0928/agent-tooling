import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Your other Macs (S17) and the sync session's Connect and share, on
/// Juniper's library after Let your apps ask, with real Git against a
/// repository on this Mac.
///
/// Connect and share publishes at once, through Agent Tooling's own checkout
/// with no folder chosen; this Mac is registered under the name typed before
/// the first publish; every failure is typed and worded by its cause, and
/// leaves this Mac unconnected; a check that stopped at something put right
/// outside the app is tried again from the footer.
@Suite("Launchpad sync connect", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadSyncConnectTests {
    /// The acceptance: Juniper's S17 publishes, with no folder picker.
    @Test func juniperPublishesAtOnceThroughItsOwnCheckout() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let flow = stage.flow
        let model = stage.model
        #expect(model.name == "Juniper")
        #expect(model.isEmpty)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Skip for now")

        model.update(address: stage.repository.address)
        await model.check.checkNow(model.request)
        #expect(model.check.result(for: model.request) != nil)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Connect and share")
        #expect(primary.key == .commandReturn)
        #expect(primary.isEnabled)
        #expect(LaunchpadStageView.footer(for: flow).secondary?.title == "Not now")

        primary.action()
        await waitUntil { model.phase == .connected(.shared) }

        let sync = try #require(stage.workspace.sync)
        #expect(sync.isConnected)
        // Agent Tooling's own checkout, beside the support folder's
        // workspaces: nobody chose a folder.
        let checkout = try #require(sync.enrollment?.checkoutPath)
        #expect(URL(filePath: checkout, directoryHint: .isDirectory) == stage.fixture.support.appending(path: "sync-checkout/"))
        // Published at once: the repository holds the library, named by this
        // Mac's own name, with its status.
        let published = try stage.repository.publishedDocument()
        #expect(published.workspaceID == stage.workspace.store.workspaceID)
        #expect(published.deviceRegistry.map(\.name) == ["Juniper"])
        #expect(try stage.repository.hasStatus(of: stage.workspace.store.deviceID))
        #expect(flow.outcomes.sync?.address == stage.repository.address)
        #expect(flow.outcomes.sync?.upToDate == false)
        #expect(LaunchpadSyncConnect.line(for: .shared) == "Shared this Mac’s setup for the first time.")
        #expect(model.connectedAddress == stage.repository.address)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Continue")

        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        #expect(flow.step == .done)
    }

    /// The name typed is the name the first publish carries: this Mac is
    /// registered before anything is published, never under the computer's
    /// own name.
    @Test func theMacIsRegisteredUnderItsTypedNameBeforeThePublish() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let model = stage.model
        model.update(address: stage.repository.address)
        model.update(name: "Juniper's MacBook")
        model.update(name: "Larch")

        model.connect(flow: stage.flow)
        await waitUntil { model.phase == .connected(.shared) }

        let published = try stage.repository.publishedDocument()
        #expect(published.deviceRegistry.map(\.name) == ["Larch"])
        #expect(stage.workspace.sync?.thisDevice?.name == "Larch")
        #expect(model.name == "Larch")
    }

    /// The session's own Connect and share, directly: registered, then
    /// published, as its outcome says.
    @Test func connectAndShareRegistersThenPublishes() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let sync = try #require(stage.workspace.sync)
        var phases: [SyncConnectPhase] = []

        let outcome = await sync.connectAndShare(
            remote: "  \(stage.repository.address)\n", deviceName: "Juniper", runner: stage.runner,
            discardStaleCheckout: { try JoinCedar.setAside($0, in: stage.fixture.support) },
            progress: { phases.append($0) })

        #expect(outcome == .shared)
        #expect(phases == [.checking, .connecting, .publishing])
        #expect(sync.enrollment?.remote == stage.repository.address)
        #expect(try stage.repository.publishedDocument().deviceRegistry.map(\.name) == ["Juniper"])
        // Once connected, a second Connect and share changes nothing.
        let again = await sync.connectAndShare(remote: stage.repository.address, deviceName: "Juniper", runner: stage.runner)
        guard case .notSaved(let sentence) = again else {
            Issue.record("a second connect was not refused: \(again)")
            return
        }
        #expect(sentence.hasSuffix("Nothing was changed."))
    }

    /// Each cause is its own: a repository that is not there, files that are
    /// not a library, another library, and a refused publish. None leaves
    /// this Mac connected.
    @Test func everyFailureIsTypedAndLeavesThisMacUnconnected() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let sync = try #require(stage.workspace.sync)
        let other = try GitLibraryFixture("wp8b-other")
        defer { other.remove() }

        let missing = stage.repository.remote.deletingLastPathComponent().appending(path: "agent-tooling-workspce.git")
        #expect(
            await sync.connectAndShare(remote: missing.path(percentEncoded: false), deviceName: "Juniper", runner: stage.runner)
                == .failed(.notFound(host: nil)))
        let files = try other.repository("files", holding: ["README.md": "Notes\n"])
        #expect(
            await sync.connectAndShare(remote: files.path(percentEncoded: false), deviceName: "Juniper", runner: stage.runner)
                == .failed(.notALibrary))
        _ = try await other.publishLibrary(from: "Fir")
        #expect(
            await sync.connectAndShare(remote: other.remote.path(percentEncoded: false), deviceName: "Juniper", runner: stage.runner)
                == .failed(.differentLibrary))
        #expect(!sync.isConnected)

        stage.runner.refusesPushes = true
        let refused = await sync.connectAndShare(
            remote: stage.repository.address, deviceName: "Juniper", runner: stage.runner,
            discardStaleCheckout: { try JoinCedar.setAside($0, in: stage.fixture.support) })
        #expect(refused == .failed(.pushRefused(host: nil)))
        // The connection it made is taken back, so the next try starts afresh.
        #expect(!sync.isConnected)
        #expect(try WorkspaceSyncEnrollmentStore(containerRoot: stage.container).read() == nil)
        #expect(stage.repository.isEmpty)

        stage.runner.refusesPushes = false
        let shared = await sync.connectAndShare(
            remote: stage.repository.address, deviceName: "Juniper", runner: stage.runner,
            discardStaleCheckout: { try JoinCedar.setAside($0, in: stage.fixture.support) })
        #expect(shared == .shared)
    }

    /// The screen words what stopped it by where: the card under the warning
    /// says the cause, and Connect and share waits for a change.
    @Test func theScreenSaysWhatStoppedTheConnection() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let model = stage.model
        stage.runner.refusesPushes = true
        model.update(address: stage.repository.address)

        model.connect(flow: stage.flow)
        await waitUntil { model.phase == .editing && model.failure != nil }

        #expect(model.failure?.title == "Couldn’t publish there")
        #expect(
            model.failure?.message
                == "That repository did not accept what this Mac published. Check that your Git sign-in can write to it. Nothing was changed."
        )
        #expect(stage.flow.outcomes.sync == nil)
        #expect(stage.flow.step == .macs)

        // A typo is caught by the check, before anything is connected.
        stage.runner.refusesPushes = false
        model.update(address: stage.repository.remote.deletingLastPathComponent().appending(path: "typo.git").path)
        await model.check.checkNow(model.request)
        #expect(model.checkProblem == .notFound(host: nil))
        #expect(!model.canConnect)
        #expect(LaunchpadSyncConnect.title(for: .notFound(host: nil)) == "Couldn’t reach that repository")
    }

    /// A check that stopped at the network says so and offers Try again ↩,
    /// which checks afresh and reads only the remote; once it passes, Connect
    /// and share is there again.
    @Test func aCheckStoppedByTheNetworkIsTriedAgain() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let model = stage.model
        stage.runner.cannotReachHost = true
        model.update(address: stage.repository.address)
        await model.check.checkNow(model.request)

        #expect(model.checkProblem == .unreachable(host: nil))
        #expect(
            model.checkProblem?.errorDescription
                == "Git could not reach that repository from this Mac. Check the network connection, then try again. Nothing was changed."
        )
        #expect(!model.canConnect)
        #expect(model.canTryAgain)
        let footer = LaunchpadStageView.footer(for: stage.flow)
        let primary = try #require(footer.primary)
        #expect(primary.title == "Try again")
        #expect(primary.key == .return)
        #expect(footer.secondary?.title == "Not now")

        stage.runner.cannotReachHost = false
        primary.action()
        await waitUntil { model.check.result(for: model.request) != nil }

        #expect(model.checkProblem == nil)
        #expect(model.canConnect)
        let connect = try #require(LaunchpadStageView.footer(for: stage.flow).primary)
        #expect(connect.title == "Connect and share")
        #expect(connect.key == .commandReturn)
        #expect(stage.workspace.sync?.isConnected == false)
        #expect(stage.repository.isEmpty)
    }

    /// Try again is offered only where checking again can pass: the network,
    /// the sign-in, the Command Line Tools, a slow host, a library that could
    /// not be read. What was typed, or what the repository holds, needs
    /// another address.
    @Test func onlyWhatIsPutRightOutsideTheAppIsTriedAgain() {
        let again: [GitRemoteProblem] = [
            .gitMissing, .unreachable(host: "github.com"), .signInFailed(host: "github.com"), .notFound(host: "github.com"),
            .timedOut(host: "github.com"), .unreadable,
        ]
        let another: [GitRemoteProblem] = [
            .invalidAddress(suggestion: nil, carriesSignIn: false), .invalidBranch, .emptyRemote, .noSuchBranch("main"),
            .notALibrary, .newerFormat, .differentLibrary, .pushRefused(host: "github.com"),
        ]
        for problem in again { #expect(LaunchpadSyncConnect.isCuredByTryingAgain(problem), "\(problem)") }
        for problem in another { #expect(!LaunchpadSyncConnect.isCuredByTryingAgain(problem), "\(problem)") }
    }

    /// A name typed while this Mac's own is read stays the person's; an
    /// address typed meanwhile is checked with the name once it is read.
    @Test func aNameReadLateNeitherReplacesATypedOneNorLeavesTheCheckBehind() async throws {
        let name = GatedCommandRunner()
        let stage = try await MacsStage.make(nameGate: name)
        defer {
            name.release()
            stage.remove()
        }
        let model = stage.model
        let loading = Task { await model.load() }
        await name.waitUntilCalled()
        model.update(address: stage.repository.address)
        name.release()
        await loading.value

        #expect(model.name == "Juniper")
        await waitUntil { model.check.result(for: model.request) != nil }
        #expect(model.check.checked?.deviceName == "Juniper")

        let typed = GatedCommandRunner()
        let other = try await MacsStage.make(nameGate: typed)
        defer {
            typed.release()
            other.remove()
        }
        let reading = Task { await other.model.load() }
        await typed.waitUntilCalled()
        other.model.update(name: "Larch")
        typed.release()
        await reading.value
        #expect(other.model.name == "Larch")
    }

    /// A rerun on a Mac that shares its library through a folder another
    /// service keeps in step opens on that, names the folder, offers nothing
    /// to copy, and records it for Done.
    @Test func aMacSharingThroughAFolderOpensOnItsFolder() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let folder = stage.fixture.world.home.root.appending(path: "Shared library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.standardizedFileURL.path
        try WorkspaceSyncEnrollmentStore(containerRoot: stage.container).write(
            try WorkspaceSyncEnrollment(
                workspaceID: stage.workspace.store.workspaceID, remote: "", checkoutPath: path, kind: .encryptedFolder))

        let rerun = stage.fixture.flow(.rerun, workspace: stage.workspace)
        rerun.go(to: .macs)
        let model = try #require(LaunchpadMacsScreen.connect(for: rerun))
        await model.load()

        #expect(model.phase == .connected(.sharesThroughFolder(path)))
        #expect(LaunchpadSyncConnect.line(for: .sharesThroughFolder(path)) == "This Mac already shares its library through a folder.")
        #expect(model.connectedAddress == nil)
        #expect(model.address.isEmpty)
        #expect(LaunchpadStageView.footer(for: rerun).primary?.title == "Continue")
        model.proceed(flow: rerun)
        #expect(rerun.outcomes.sync?.address == path)
        #expect(rerun.outcomes.sync?.upToDate == true)
    }

    /// V9: the scp form is refused before anything runs, with the HTTPS form
    /// to use instead, and Connect and share waits for it.
    @Test func theScpFormIsHelpedNotRun() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let model = stage.model

        model.update(address: "git@github.com:you/agent-tooling-workspace.git")
        #expect(model.addressProblem?.errorDescription == "Enter a repository address without a user name or password in it.")
        #expect(!model.canConnect)
        #expect(model.check.phase == .idle)
        model.useSuggestion()
        #expect(model.address == "https://github.com/you/agent-tooling-workspace.git")
        #expect(model.addressProblem == nil)
    }

    /// Not now and Skip for now connect nothing and move on; Home keeps its
    /// row for the other Macs.
    @Test func notNowConnectsNothing() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        stage.model.update(address: stage.repository.address)

        try #require(LaunchpadStageView.footer(for: stage.flow).secondary).action()

        #expect(stage.flow.step == .done)
        #expect(stage.flow.outcomes.sync == nil)
        #expect(stage.workspace.sync?.isConnected == false)
        #expect(stage.repository.isEmpty)
    }

    /// A rerun on a Mac that already shares its library opens on the result,
    /// with its repository, and records it for Done.
    @Test func aConnectedMacOpensOnItsResult() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        stage.model.update(address: stage.repository.address)
        stage.model.connect(flow: stage.flow)
        await waitUntil { stage.model.phase == .connected(.shared) }

        let rerun = stage.fixture.flow(.rerun, workspace: stage.workspace)
        let model = try #require(LaunchpadMacsScreen.connect(for: rerun))
        await model.load()
        #expect(model.phase == .connected(.alreadyConnected))
        #expect(model.address == stage.repository.address)
        #expect(LaunchpadSyncConnect.line(for: .alreadyConnected) == "This Mac already shares its library through this repository.")
        model.proceed(flow: rerun)
        #expect(rerun.outcomes.sync?.address == stage.repository.address)
        #expect(rerun.outcomes.sync?.upToDate == true)
    }

    /// The check is stoppable; connecting and publishing are waited out,
    /// "Publishing…", and ⎋ does nothing then.
    @Test func publishingIsWaitedOut() async throws {
        let pushes = GatedCommandRunner()
        let stage = try await MacsStage.make(pushGate: pushes)
        defer { stage.remove() }
        let model = stage.model
        model.update(address: stage.repository.address)

        model.connect(flow: stage.flow)
        await pushes.waitUntilCalled()
        await waitUntil { model.phase == .publishing }
        #expect(stage.flow.interruption == .finishing(LaunchpadCopy.Footer.publishing))
        #expect(LaunchpadStageView.footer(for: stage.flow).primary?.busyTitle == "Publishing…")
        model.stop()
        stage.flow.escape()
        #expect(model.phase == .publishing)

        let quit = Task { await stage.flow.finishPendingWork() }
        pushes.release()
        await quit.value
        #expect(model.phase == .connected(.shared))
    }

    /// A Stop while the repository is checked keeps nothing.
    @Test func aStopWhileCheckingKeepsNothing() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        let model = stage.model
        model.update(address: stage.repository.address)
        stage.runner.holdsListings = GatedCommandRunner()

        model.connect(flow: stage.flow)
        await stage.runner.holdsListings?.waitUntilCalled()
        #expect(model.phase == .checking)
        #expect(stage.flow.interruption == .stoppable)
        guard case .stop(let stop) = LaunchpadStageView.footer(for: stage.flow).later else {
            Issue.record("the later slot is not Stop while checking")
            return
        }
        stop()
        await waitUntil { model.phase == .editing }

        #expect(stage.workspace.sync?.isConnected == false)
        #expect(stage.repository.isEmpty)
        #expect(model.failure == nil)
    }
}

// MARK: - Juniper's stage at Your other Macs

/// Juniper's library after Let your apps ask, at Your other Macs, with an
/// empty private repository on this Mac and a stage whose Git runs for real.
@MainActor
struct MacsStage {
    let fixture: LaunchpadFixture
    let workspace: WorkspaceLaunch.Workspace
    let flow: LaunchpadFlow
    let model: LaunchpadSyncConnect
    let runner: JoinGitRunner
    let repository: MacsRepository

    var container: URL { workspace.store.databaseURL.deletingLastPathComponent() }

    /// `nameGate` holds the read of this Mac's name, and with it the model's
    /// first load, which the test then runs itself.
    static func make(pushGate: GatedCommandRunner? = nil, nameGate: GatedCommandRunner? = nil) async throws -> MacsStage {
        var fixture = try await LaunchpadFixture(.juniper)
        do {
            let runner = JoinGitRunner(tools: fixture.world.scriptedRunner(), homeURL: fixture.home, pushGate: pushGate)
            fixture.environment.makeRunner = { _ in runner }
            if let nameGate {
                fixture.environment.deviceName = {
                    _ = try? await nameGate.run(
                        executable: "/usr/sbin/scutil", arguments: ["--get", "ComputerName"], currentDirectory: nil)
                    return "Juniper"
                }
            }
            let repository = try MacsRepository(in: fixture.world.home.root)
            let (flow, sample) = try await fixture.flow(at: .afterAsk)
            flow.go(to: .macs)
            let support = fixture.support
            let model = flow.model(for: .macs) {
                LaunchpadSyncConnect(
                    workspace: sample.workspace, environment: flow.environment, checkDelay: .zero,
                    discardStaleCheckout: { try JoinCedar.setAside($0, in: support) })
            }
            if nameGate == nil { await model.load() }
            return MacsStage(
                fixture: fixture, workspace: sample.workspace, flow: flow, model: model, runner: runner, repository: repository)
        } catch {
            fixture.remove()
            throw error
        }
    }

    func remove() { fixture.remove() }
}

/// An empty private repository on this Mac, and what was published into it.
struct MacsRepository {
    let remote: URL

    init(in folder: URL) throws {
        remote = folder.appending(path: "agent-tooling-workspace.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try GitTestFixture.git(
            ["init", "--quiet", "--bare", "--initial-branch", "main", remote.path(percentEncoded: false)], in: remote,
            checkingStatus: true)
    }

    /// A repository that is already there.
    init(existing remote: URL) {
        self.remote = remote
    }

    var address: String { remote.path(percentEncoded: false) }

    /// Whether nothing was ever published there.
    var isEmpty: Bool { (try? Self.output(["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: remote))?.isEmpty ?? true }

    /// The library on its branch, as another Mac would read it.
    func publishedDocument() throws -> PortableWorkspaceDocument {
        try AgentToolingCoding.decoder().decode(
            PortableWorkspaceDocument.self, from: Data(try Self.output(["show", "main:workspace.json"], in: remote).utf8))
    }

    /// Whether the branch holds `device`'s status file.
    func hasStatus(of device: WorkspaceObjectID) throws -> Bool {
        let listed = try Self.output(["ls-tree", "-r", "--name-only", "main"], in: remote)
        let key = device.rawValue.uuidString.lowercased()
        return listed.split(separator: "\n").contains { $0.hasPrefix("status/") && $0.contains(key) }
    }

    private static func output(_ arguments: [String], in directory: URL) throws -> String {
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
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
