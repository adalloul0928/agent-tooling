import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// One preflight report: a check and where it got to.
private struct Report: Equatable, Sendable, CustomStringConvertible {
    let check: GitRemotePreflight.Check
    let state: GitRemotePreflight.CheckState

    init(_ check: GitRemotePreflight.Check, _ state: GitRemotePreflight.CheckState) {
        self.check = check
        self.state = state
    }

    var description: String { "\(check) \(state)" }

    static let allPassed: [Report] = GitRemotePreflight.Check.allCases.flatMap { [Report($0, .started), Report($0, .passed)] }

    /// Every check before `check` passed, and `check` failed.
    static func failed(at check: GitRemotePreflight.Check) -> [Report] {
        GitRemotePreflight.Check.allCases.filter { $0.rawValue < check.rawValue }.flatMap { [Report($0, .started), Report($0, .passed)] }
            + [Report(check, .started), Report(check, .failed)]
    }
}

/// Runs the preflight and keeps what it reported along the way.
private func preflight(
    _ remote: String, branch: String = "main", deviceName: String = "Cedar", expecting workspace: WorkspaceObjectID? = nil,
    thisDevice: WorkspaceObjectID? = nil, runner: any CommandRunning, scratch: URL
) async throws -> (Result<GitRemotePreflightResult, GitRemoteProblem>, [Report]) {
    let reports = EventRecorder<Report>()
    let result = try await GitRemotePreflight.run(
        remote: remote, branch: branch, deviceName: deviceName, expectingWorkspace: workspace, thisDevice: thisDevice,
        runner: runner, scratch: scratch, progress: { reports.record(Report($0, $1)) })
    return (result, reports.events)
}

/// Agent Tooling's own connection as setup records it in a library: a
/// server under its name, bound to the Mac that runs it.
private func ownConnectionDraft() -> MCPDraft {
    var draft = MCPDraft()
    draft.name = AgentToolingConnection.declaredName
    draft.transport = .stdio
    draft.endpoint = "/Applications/AgentTooling.app/Contents/Helpers/AgentToolingMCP"
    return draft
}

/// J01's "Before joining" checks and S17's check before connecting: against
/// real repositories on this Mac, and against Git's own failure messages,
/// scripted. Real Git costs seconds a test, so the real cases share remotes.
@Suite("Git remote preflight", .serialized, .timeLimit(.minutes(5)))
struct GitRemotePreflightTests {
    @Test func aPublishedLibraryPassesEveryCheckAndSaysWhatItHolds() async throws {
        let fixture = try GitLibraryFixture("preflight-published")
        defer { fixture.remove() }
        let codex = PublishedDeviceStatus.AppSummary(
            surface: .codexCLI, installed: true, version: "0.164.0", skillCount: 2, pluginCount: 1, mcpServerCount: 1)
        let juniper = try await fixture.publishLibrary(from: "Juniper", skills: ["Release Notes", "Frontend Design"], statusApps: [codex])
        // An older Mac called Cedar is still in the library, and Juniper
        // carries Agent Tooling's own connection, bound to Juniper.
        let snapshot = try #require(try juniper.store.snapshot())
        _ = try await juniper.service.registerDevice(
            .init(expectedRevisionID: snapshot.document.revision.id, deviceID: WorkspaceObjectID(), name: "Cedar"))
        let head = try #require(try juniper.store.snapshot()).document.revision.id
        _ = try await juniper.service.intakeManagedMCPServer(
            try ManagedMCPServerIntakeCommand(expectedRevisionID: head, draft: ownConnectionDraft()))
        // The library holds it as a row, and counts it as no tool of its own.
        let library = try WorkspaceLibraryReadModel(snapshot: #require(try juniper.store.snapshot()))
        #expect(library.rows.count == 3)
        #expect(library.toolCount == 2)
        // Oak used the library once and was retired; its last status stays.
        _ = try await fixture.retiredMac("Oak", in: juniper)
        let runner = fixture.runner(for: try fixture.home("Cedar"))
        let probe = try await GitWorkspaceTransport.enroll(
            remote: fixture.remote.path, checkout: fixture.root.appending(path: "probe"), runner: runner)
        let probed = try await probe.remoteState()
        #expect(Set(probed.deviceStatuses.map(\.name)) == ["Juniper", "Oak"])

        // Pasted with a line break after it, as an address copied from
        // Settings › Sync on the other Mac can be.
        let (joining, reports) = try await preflight(fixture.remote.path + "\n", runner: runner, scratch: fixture.root)

        let result = try joining.get()
        #expect(reports == Report.allPassed)
        #expect(result.head == probed.head)
        #expect(result.workspaceID == juniper.workspaceID)
        // The two skills. The helper is bound to each Mac, not a tool the
        // library carries (J01's "13 tools" on Juniper leaves it out).
        #expect(result.toolCount == 2)
        #expect(result.deviceNames == ["Juniper", "Cedar"])
        #expect(result.suggestedName == "Cedar 2")
        // Retired Oak's status is no other Mac's news.
        #expect(result.statuses.map(\.name) == ["Juniper"])
        #expect(result.statuses.first?.apps == [codex])
        // The preflight works in a folder of its own and leaves nothing.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix("preflight-") })

        // Connecting the Mac that published: the same library is fine, and
        // the Mac is neither numbered against nor listed beside itself.
        let (reconnecting, _) = try await preflight(
            fixture.remote.path, deviceName: juniper.name, expecting: juniper.workspaceID, thisDevice: juniper.deviceID,
            runner: fixture.runner(for: juniper.home), scratch: fixture.root)
        let reconnected = try reconnecting.get()
        #expect(reconnected.suggestedName == "Juniper")
        #expect(reconnected.deviceNames == ["Cedar"])
        #expect(reconnected.statuses.isEmpty)

        // Connecting a Mac with a library of its own: refused before anything is written.
        let (connecting, connectReports) = try await preflight(
            fixture.remote.path, deviceName: "Oak", expecting: WorkspaceObjectID(), runner: runner, scratch: fixture.root)
        #expect(connecting == .failure(.differentLibrary))
        #expect(connectReports == Report.failed(at: .holdsLibrary))
    }

    @Test func anEmptyRepositoryCannotBeJoinedButCanBeConnected() async throws {
        let fixture = try GitLibraryFixture("preflight-empty")
        defer { fixture.remove() }
        let runner = fixture.runner(for: try fixture.home("Juniper"))

        let (joining, reports) = try await preflight(fixture.remote.path, runner: runner, scratch: fixture.root)
        #expect(joining == .failure(.emptyRemote))
        #expect(reports == Report.failed(at: .holdsLibrary))

        let (connecting, connectReports) = try await preflight(
            fixture.remote.path, deviceName: "Juniper", expecting: WorkspaceObjectID(), runner: runner, scratch: fixture.root)
        #expect(
            connecting
                == .success(.init(head: nil, workspaceID: nil, toolCount: 0, deviceNames: [], suggestedName: "Juniper", statuses: [])))
        #expect(connectReports == Report.allPassed)
    }

    @Test func aBranchTheRepositoryDoesNotHaveIsATypoNotAnEmptyRepository() async throws {
        let fixture = try GitLibraryFixture("preflight-branch")
        defer { fixture.remove() }
        let repository = try fixture.repository("library", holding: ["README.md": "# Library\n"])
        let recording = RecordingRunner(base: fixture.runner(for: try fixture.home("Cedar")))

        let (joining, reports) = try await preflight(repository.path, branch: "mian", runner: recording, scratch: fixture.root)

        #expect(joining == .failure(.noSuchBranch("mian")))
        #expect(reports == Report.failed(at: .holdsLibrary))
        // Only once the branch is missing does Git list the others.
        #expect(
            recording.gitCalls.events.filter { $0.first == "ls-remote" } == [
                ["ls-remote", "--heads", "--", repository.path, "refs/heads/mian"], ["ls-remote", "--heads", "--", repository.path],
            ])

        // Connecting Juniper there is fine: a branch not there yet is where
        // its library goes.
        let (connecting, connectReports) = try await preflight(
            repository.path, branch: "library", deviceName: "Juniper", expecting: WorkspaceObjectID(),
            runner: fixture.runner(for: try fixture.home("Juniper")), scratch: fixture.root)
        #expect(try connecting.get().head == nil)
        #expect(connectReports == Report.allPassed)
    }

    @Test func aMissingRepositoryIsNotFoundAndNotEmpty() async throws {
        let fixture = try GitLibraryFixture("preflight-missing")
        defer { fixture.remove() }
        let missing = fixture.root.appending(path: "agent-tooling-workspce.git").path

        let (result, reports) = try await preflight(
            missing, runner: fixture.runner(for: try fixture.home("Cedar")), scratch: fixture.root)

        #expect(result == .failure(.notFound(host: nil)))
        #expect(reports == Report.failed(at: .reachable))
    }

    @Test func whatARepositoryHoldsDecidesTheThirdAndFourthChecks() async throws {
        let fixture = try GitLibraryFixture("preflight-contents")
        defer { fixture.remove() }
        let runner = fixture.runner(for: try fixture.home("Cedar"))
        let workspace = WorkspaceObjectID()
        let current = PortableWorkspaceDocument.currentSchemaVersion
        let id = workspace.rawValue.uuidString.lowercased()
        let cases: [(files: [String: String], problem: GitRemoteProblem)] = [
            (["README.md": "# Notes\n"], .notALibrary),
            (["workspace.json": "{\"name\": \"an editor's workspace\"}"], .notALibrary),
            (["workspace.json": GitLibraryFixture.newerLibraryFile(for: workspace)], .newerFormat),
            (
                ["workspace.json": "{\"schemaVersion\": \(current), \"minimumReaderVersion\": \(current), \"workspaceID\": \"\(id)\"}"],
                .unreadable
            ),
            (["workspace.json": "{\"schemaVersion\": \(current), \"workspa"], .unreadable),
        ]
        for (index, item) in cases.enumerated() {
            let repository = try fixture.repository("holding-\(index)", holding: item.files)
            let (result, reports) = try await preflight(repository.path, runner: runner, scratch: fixture.root)
            #expect(result == .failure(item.problem), "\(item.files)")
            let check = try #require(item.problem.failedCheck)
            #expect(reports == Report.failed(at: check), "\(item.files)")
        }
    }

    @Test(arguments: [
        (
            "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
            GitRemoteProblem.signInFailed(host: "github.com")
        ),
        (
            "remote: Invalid username or token.\nfatal: Authentication failed for 'https://github.com/you/agent-tooling-workspace.git/'",
            .signInFailed(host: "github.com")
        ),
        (
            "remote: Permission to you/agent-tooling-workspace.git denied to cedar.\n"
                + "fatal: unable to access 'https://github.com/you/agent-tooling-workspace.git/': The requested URL returned error: 403",
            .signInFailed(host: "github.com")
        ),
        (
            "remote: Repository not found.\nfatal: repository 'https://github.com/you/agent-tooling-workspce.git/' not found",
            .notFound(host: "github.com")
        ),
        (
            "fatal: unable to access 'https://github.com/you/agent-tooling-workspace.git/': Could not resolve host: github.com",
            .unreachable(host: "github.com")
        ),
        (
            "fatal: unable to access 'https://github.com/you/agent-tooling-workspace.git/': "
                + "Failed to connect to github.com port 443 after 3 ms: Couldn't connect to server",
            .unreachable(host: "github.com")
        ),
        (
            "fatal: unable to access 'https://github.com/you/agent-tooling-workspace.git/': "
                + "Operation timed out after 300000 milliseconds with 0 out of 0 bytes received",
            .timedOut(host: "github.com")
        ),
        ("fatal: something Git has not said before", .notFound(host: "github.com")),
    ])
    func gitsOwnMessageDecidesTheCause(_ standardError: String, _ problem: GitRemoteProblem) async throws {
        let scratch = try TemporaryFolder("preflight-scripted").url
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = ScriptedReachRunner(listing: .output(.init(status: 128, standardOutput: "", standardError: standardError)))

        let (result, reports) = try await preflight(ScriptedReachRunner.remote, runner: runner, scratch: scratch)

        #expect(result == .failure(problem))
        #expect(reports == Report.failed(at: .reachable))
        // Git's text, which can carry the address and a path, is never what is shown.
        let shown = try #require(problem.errorDescription)
        #expect(!shown.contains("fatal"))
        #expect(shown.hasSuffix("Nothing was changed."))
    }

    @Test func aRepositoryThatNeverAnswersTimesOut() async throws {
        let scratch = try TemporaryFolder("preflight-timeout").url
        defer { try? FileManager.default.removeItem(at: scratch) }

        let (result, reports) = try await preflight(
            ScriptedReachRunner.remote, runner: ScriptedReachRunner(listing: .timeOut), scratch: scratch)

        #expect(result == .failure(.timedOut(host: "github.com")))
        #expect(reports == Report.failed(at: .reachable))
    }

    @Test func gitIsNeverRunWithoutTheCommandLineTools() async throws {
        let scratch = try TemporaryFolder("preflight-no-git").url
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = ScriptedCommandRunner(byTool: [
            "xcode-select": [
                ["-p"]: .output(
                    .init(status: 2, standardOutput: "", standardError: "xcode-select: error: unable to get active developer directory"))
            ]
        ])

        let (result, reports) = try await preflight(ScriptedReachRunner.remote, runner: runner, scratch: scratch)

        #expect(result == .failure(.gitMissing))
        #expect(reports == Report.failed(at: .gitInstalled))
        // /usr/bin/git would have opened the Command Line Tools installer.
        #expect(await runner.launches.map(\.basename) == ["xcode-select"])
        #expect(await runner.launches.first?.executable == "/usr/bin/xcode-select")
    }

    @Test func anAddressOrBranchTheFieldRefusesRunsNothing() async throws {
        let scratch = try TemporaryFolder("preflight-field").url
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = ScriptedCommandRunner([:])

        let (scp, scpReports) = try await preflight(
            "git@github.com:you/agent-tooling-workspace.git", runner: runner, scratch: scratch)
        let (http, httpReports) = try await preflight(
            "http://github.com/you/agent-tooling-workspace.git", runner: runner, scratch: scratch)
        let branch = try await GitRemotePreflight.run(
            remote: ScriptedReachRunner.remote, branch: "with space", deviceName: "Cedar", runner: runner, scratch: scratch)

        #expect(
            scp == .failure(.invalidAddress(suggestion: "https://github.com/you/agent-tooling-workspace.git", carriesSignIn: true)))
        #expect(
            http == .failure(.invalidAddress(suggestion: "https://github.com/you/agent-tooling-workspace.git", carriesSignIn: false)))
        #expect(scpReports.isEmpty && httpReports.isEmpty)
        #expect(branch == .failure(.invalidBranch))
        #expect(await runner.launches.isEmpty)
    }

    @Test func aCancelledPreflightStopsAndSaysSo() async throws {
        let scratch = try TemporaryFolder("preflight-cancel").url
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gate = GatedCommandRunner()
        let runner = ScriptedReachRunner(listing: .held(gate))

        let running = Task { try await preflight(ScriptedReachRunner.remote, runner: runner, scratch: scratch) }
        await gate.waitUntilCalled()
        running.cancel()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(gate.cancelledCalls == 1)
    }

    @Test func everyCauseIsWordedForThePersonReadingIt() {
        // V08's drawn message, word for word, then the other causes J01 and
        // S17 name. Every failure that wrote nothing ends with "Nothing was
        // changed."; the field's own help does not.
        let cases: [(GitRemoteProblem, String)] = [
            (
                .notFound(host: "github.com"),
                "github.com has no repository at this address that this Mac can see. "
                    + "Check the spelling, or your Git sign-in for github.com. Nothing was changed."
            ),
            (.signInFailed(host: "github.com"), "Git could not sign in to github.com from this Mac. Nothing was changed."),
            (
                .unreachable(host: "github.com"),
                "Git could not reach github.com from this Mac. Check the network connection, then try again. Nothing was changed."
            ),
            (.timedOut(host: "github.com"), "github.com did not answer in time. Try again in a moment. Nothing was changed."),
            (
                .emptyRemote,
                "That repository holds no workspace yet. Connect the Mac that has your library first, so it publishes one. "
                    + "Nothing was changed."
            ),
            (.newerFormat, "This library needs a newer Agent Tooling. Update this Mac first. Nothing was changed."),
            (.noSuchBranch("mian"), "That repository has no branch called “mian”. Check the branch name. Nothing was changed."),
            (
                .gitMissing,
                "Git is not installed on this Mac. Install Apple’s Command Line Tools, then try again. Nothing was changed."
            ),
            (
                .notALibrary,
                "That repository holds other files, not an Agent Tooling library. "
                    + "Check the address, or use an empty private repository. Nothing was changed."
            ),
            (
                .unreadable,
                "That repository holds a library this Mac could not read. Its workspace.json may be damaged. Nothing was changed."
            ),
            (
                .differentLibrary,
                "That repository holds a different library. Use an empty private repository for this Mac’s library. Nothing was changed."
            ),
            (
                .pushRefused(host: "github.com"),
                "github.com did not accept what this Mac published. Check that your Git sign-in can write to it. Nothing was changed."
            ),
            (.notFound(host: nil), "There is no repository at that address on this Mac. Check the spelling. Nothing was changed."),
            (
                .invalidAddress(suggestion: "https://github.com/you/library.git", carriesSignIn: true),
                "Enter a repository address without a user name or password in it."
            ),
            (
                .invalidAddress(suggestion: "https://github.com/you/library.git", carriesSignIn: false),
                "Enter a repository address that starts with https://."
            ),
        ]
        for (problem, words) in cases {
            #expect(problem.errorDescription == words)
            #expect(!words.contains("!") && !words.contains("...") && !words.contains("'"), "\(words)")
        }
        #expect(GitRemoteProblem.noSuchBranch("mian").failedCheck == .holdsLibrary)
        // Each one names its own check, which is the row J01 marks failed.
        #expect(GitRemoteProblem.notFound(host: "github.com").failedCheck == .reachable)
        #expect(GitRemoteProblem.gitMissing.failedCheck == .gitInstalled)
        #expect(GitRemoteProblem.emptyRemote.failedCheck == .holdsLibrary)
        #expect(GitRemoteProblem.newerFormat.failedCheck == .readable)
        #expect(GitRemoteProblem.invalidAddress(suggestion: nil, carriesSignIn: false).failedCheck == nil)
    }
}

/// Answers the Command Line Tools check and `git init` as a Mac with Git
/// does, and `ls-remote` as scripted: the shape of every reach failure.
private struct ScriptedReachRunner: CommandRunning {
    /// How `ls-remote` ends.
    enum Listing: Sendable {
        case output(CommandOutput)
        case timeOut
        /// Held by `gate` until it is released or the caller is cancelled.
        case held(GatedCommandRunner)
    }

    static let remote = "https://github.com/you/agent-tooling-workspace.git"

    let listing: Listing

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        let prefix = GitWorkspaceTransport.prefix
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "xcode-select":
            return .init(status: 0, standardOutput: "/Library/Developer/CommandLineTools\n", standardError: "")
        case "git" where arguments == ["--version"]:
            return .init(status: 0, standardOutput: "git version 2.50.1 (Apple Git-155)\n", standardError: "")
        case "git" where arguments == prefix + ["init", "--quiet"]:
            return .init(status: 0, standardOutput: "", standardError: "")
        case "git" where arguments == prefix + ["ls-remote", "--heads", "--", Self.remote, "refs/heads/main"]:
            switch listing {
            case .output(let output): return output
            case .timeOut: throw ProcessCommandRunnerError.timedOut(executable)
            case .held(let gate):
                return try await gate.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
            }
        default:
            return .init(status: 1, standardOutput: "", standardError: "not scripted")
        }
    }
}

/// Runs every command for real, and keeps the arguments each Git command was
/// given, without the transport's fixed prefix.
private struct RecordingRunner: CommandRunning {
    let base: ProcessCommandRunner
    let gitCalls = EventRecorder<[String]>()

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        if URL(fileURLWithPath: executable).lastPathComponent == "git" {
            let prefix = GitWorkspaceTransport.prefix
            gitCalls.record(arguments.starts(with: prefix) ? Array(arguments.dropFirst(prefix.count)) : arguments)
        }
        return try await base.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}

/// The transport's own failures, typed: a fetch that fails is never read as
/// an empty repository, a refused push is not "another Mac published", and a
/// checkout an earlier attempt left is set aside rather than misread.
@Suite("Git transport failures", .serialized, .timeLimit(.minutes(5)))
struct GitTransportFailureTests {
    @Test func aRepositoryThatCannotBeReadIsNeverReadAsEmpty() async throws {
        let fixture = try GitLibraryFixture("transport-missing")
        defer { fixture.remove() }
        let missing = fixture.root.appending(path: "agent-tooling-workspce.git").path

        await #expect(throws: GitWorkspaceTransportError.remote(.notFound(host: nil))) {
            _ = try await GitWorkspaceTransport.enroll(
                remote: missing, checkout: fixture.root.appending(path: "checkout"), runner: fixture.runner(for: fixture.root))
        }
        // An empty repository still reads as one: no head and no document.
        let empty = try await GitWorkspaceTransport.enroll(
            remote: fixture.remote.path, checkout: fixture.root.appending(path: "empty-checkout"),
            runner: fixture.runner(for: fixture.root))
        let state = try await empty.remoteState()
        #expect(state.head == nil)
        #expect(state.document == nil)
    }

    @Test(arguments: [
        (
            "fatal: unable to access 'https://github.com/you/library.git/': Could not resolve host: github.com",
            GitRemoteProblem.unreachable(host: "github.com")
        ),
        ("fatal: could not read Username for 'https://github.com': Device not configured", .signInFailed(host: "github.com")),
        ("remote: Repository not found.\nfatal: repository 'https://github.com/you/library.git/' not found", .notFound(host: "github.com")),
    ])
    func aFailedFetchIsTypedAndNamesTheHost(_ standardError: String, _ problem: GitRemoteProblem) async throws {
        let checkout = try TemporaryFolder("transport-scripted").url
        defer { try? FileManager.default.removeItem(at: checkout) }
        let prefix = GitWorkspaceTransport.prefix
        let runner = ScriptedCommandRunner(byTool: [
            "git": [
                prefix + ["fetch", "--quiet", "--no-tags", "origin", "main"]: .output(
                    .init(status: 128, standardOutput: "", standardError: standardError)),
                prefix + ["remote", "get-url", "origin"]: .standardOutput("https://github.com/you/library.git\n"),
            ]
        ])
        let transport = try GitWorkspaceTransport(checkout: checkout, runner: runner)

        await #expect(throws: GitWorkspaceTransportError.remote(problem)) { _ = try await transport.remoteState() }
        // What a sync pass shows: the cause, which the pass closes with
        // "Nothing was changed." itself.
        #expect(GitWorkspaceTransportError.remote(problem).errorDescription == problem.sentence)
        #expect(GitWorkspaceTransportError.remote(problem).errorDescription?.hasSuffix("Nothing was changed.") == false)
    }

    @Test func aBranchTheRemoteDoesNotHaveYetIsNoHead() async throws {
        let checkout = try TemporaryFolder("transport-no-branch").url
        defer { try? FileManager.default.removeItem(at: checkout) }
        let prefix = GitWorkspaceTransport.prefix
        let runner = ScriptedCommandRunner(byTool: [
            "git": [
                prefix + ["fetch", "--quiet", "--no-tags", "origin", "main"]: .output(
                    .init(status: 128, standardOutput: "", standardError: "fatal: couldn't find remote ref main"))
            ]
        ])
        let transport = try GitWorkspaceTransport(checkout: checkout, runner: runner)

        let state = try await transport.remoteState()

        #expect(state.head == nil)
        #expect(state.document == nil)
    }

    @Test func aRefusedPushIsSaidAsSuchAndAMovedRemoteIsStillAMerge() async throws {
        let fixture = try GitLibraryFixture("transport-push")
        defer { fixture.remove() }
        let checkout = fixture.root.appending(path: "checkout")
        _ = try await GitTestFixture.enroll(remote: fixture.remote, checkout: checkout)
        let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: WorkspaceObjectID())))
        let refusals = [
            "To /tmp/remote.git\n ! [remote rejected] HEAD -> main (pre-receive hook declined)\nerror: failed to push some refs",
            // Nothing recognisable, and the remote did not move: refused all the same.
            "error: the far end said no in a way nobody has seen before",
        ]
        for refusal in refusals {
            let transport = try GitWorkspaceTransport(
                checkout: checkout, runner: PushRefusingRunner(base: fixture.runner(for: fixture.root), refusal: refusal))
            await #expect(throws: GitWorkspaceTransportError.remote(.pushRefused(host: nil))) {
                _ = try await transport.publish(document: document, expectedRemoteHead: nil)
            }
        }
        // Another Mac publishes while this one pushes: Git's own rejection,
        // with the remote moved on, is still a merge to make, at their commit.
        let other = try fixture.repository("other-mac", holding: ["README.md": "# Published elsewhere\n"])
        let theirs = try await fixture.runner(for: fixture.root).run(
            executable: "/usr/bin/git", arguments: ["rev-parse", "HEAD"], currentDirectory: other
        ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = fixture.remote
        let racing = try GitWorkspaceTransport(
            checkout: checkout,
            runner: PushRefusingRunner(
                base: fixture.runner(for: fixture.root),
                refusal: "To \(remote.path)\n ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs",
                beforeRefusing: {
                    try GitTestFixture.git(
                        ["-c", "core.hooksPath=/dev/null", "push", "--quiet", remote.path, "HEAD:refs/heads/main"], in: other,
                        checkingStatus: true)
                }))
        await #expect(throws: GitWorkspaceTransportError.remoteAdvanced(remoteHead: theirs)) {
            _ = try await racing.publish(document: document, expectedRemoteHead: nil)
        }
        #expect(GitRemoteFailure.isRejectedBecauseRemoteMoved(" ! [rejected]        HEAD -> main (fetch first)"))
        #expect(GitRemoteFailure.isRejectedBecauseRemoteMoved(" ! [rejected]        HEAD -> main (non-fast-forward)"))
        #expect(!GitRemoteFailure.isRejectedBecauseRemoteMoved(" ! [remote rejected] HEAD -> main (protected branch hook declined)"))
        #expect(
            GitRemoteFailure.problem(
                standardError: "remote: Permission to you/library.git denied to cedar.\nfatal: The requested URL returned error: 403",
                host: "github.com", pushing: true) == .pushRefused(host: "github.com"))
    }

    @Test func aCheckoutAnEarlierAttemptLeftIsSetAsideForAFreshOne() async throws {
        let fixture = try GitLibraryFixture("transport-fresh")
        defer { fixture.remove() }
        let other = try fixture.repository("other-library", holding: ["README.md": "# Elsewhere\n"])
        let checkout = fixture.root.appending(path: "sync-checkout", directoryHint: .isDirectory)
        let runner = fixture.runner(for: fixture.root)
        _ = try await GitWorkspaceTransport.enroll(remote: other.path, checkout: checkout, runner: runner)

        // Without a fresh start the stale clone is named for what it is, not
        // misread as an address with a user name in it.
        await #expect(throws: GitWorkspaceTransportError.checkoutHasAnotherRemote) {
            _ = try await GitWorkspaceTransport.enroll(remote: fixture.remote.path, checkout: checkout, runner: runner)
        }
        let setAside = fixture.root.appending(path: "set-aside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: setAside, withIntermediateDirectories: true)
        let discarded = EventRecorder<URL>()
        let discard: @Sendable (URL) throws -> Void = { item in
            discarded.record(item)
            try FileManager.default.moveItem(at: item, to: setAside.appending(path: UUID().uuidString))
        }
        try GitWorkspaceTransport.prepareFreshCheckout(at: checkout, discard: discard)
        let fresh = try await GitWorkspaceTransport.enroll(remote: fixture.remote.path, checkout: checkout, runner: runner)

        #expect(discarded.events == [checkout])
        #expect(try await fresh.remoteState().head == nil)
        // Nothing moved aside is lost: the stale clone is where discard put it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: setAside.path).count == 1)

        // A folder that is not there, or is empty, is left as it is. A link is
        // set aside itself, and what it points at is not touched.
        let missing = fixture.root.appending(path: "never-made", directoryHint: .isDirectory)
        try GitWorkspaceTransport.prepareFreshCheckout(at: missing, discard: discard)
        let empty = fixture.root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try GitWorkspaceTransport.prepareFreshCheckout(at: empty, discard: discard)
        let link = fixture.root.appending(path: "linked-checkout")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try GitWorkspaceTransport.prepareFreshCheckout(at: link, discard: discard)
        #expect(discarded.events == [checkout, link])
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "README.md").path))
    }

    @Test func aLibraryFromANewerAgentToolingOrNoLibraryIsNamedAsSuch() async throws {
        let fixture = try GitLibraryFixture("transport-newer")
        defer { fixture.remove() }
        let cases: [(files: [String: String], problem: GitRemoteProblem)] = [
            (["workspace.json": GitLibraryFixture.newerLibraryFile(for: WorkspaceObjectID())], .newerFormat),
            // Some other JSON under that name: no library, as the preflight
            // says, rather than a library that could not be read.
            (["workspace.json": "{\"name\": \"an editor's workspace\"}"], .notALibrary),
        ]
        for (index, item) in cases.enumerated() {
            let repository = try fixture.repository("holding-\(index)", holding: item.files)
            let transport = try await GitWorkspaceTransport.enroll(
                remote: repository.path, checkout: fixture.root.appending(path: "checkout-\(index)"),
                runner: fixture.runner(for: fixture.root))

            await #expect(throws: GitWorkspaceTransportError.remote(item.problem)) { _ = try await transport.remoteState() }
        }
    }
}

/// Runs every command for real except a push, which ends as the remote
/// refusing it said, once `beforeRefusing` has run: another Mac publishing
/// first, say.
private struct PushRefusingRunner: CommandRunning {
    let base: ProcessCommandRunner
    let refusal: String
    var beforeRefusing: @Sendable () throws -> Void = {}

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        if arguments.contains("push") {
            try beforeRefusing()
            return .init(status: 1, standardOutput: "", standardError: refusal)
        }
        return try await base.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}
