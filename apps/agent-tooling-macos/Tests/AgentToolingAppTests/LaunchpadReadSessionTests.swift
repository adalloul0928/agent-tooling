import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The read (S05): every chosen app read at once through the scripted first
/// read, the sign-in read beside it, the library made only once every app is
/// read or skipped, Stop that keeps nothing, Skip that stops one app and its
/// sign-in, late events dropped, the notices a slow read raises, and the
/// rerun's adopt. Every wait is on what the read changes, never on time.
@Suite("Launchpad read session", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadReadSessionTests {
    // MARK: - The commit point

    /// The library is created only after the last read lands, and nothing
    /// advances on its own: the read waits on S05 with Continue ready.
    @Test func theLibraryIsCreatedOnlyAfterTheLastRead() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await gate.waitUntilCalled(times: 3)
        #expect(read.phase == .reading)
        #expect(read.interruption == .stoppable)
        #expect(!fixture.hasWorkspace)
        #expect(flow.workspace == nil)

        gate.release()
        await waitUntil { read.phase == .finished }

        #expect(fixture.hasWorkspace)
        #expect(flow.workspace?.device.observations.count == 3)
        #expect(flow.step == .reads)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.isEnabled)
        #expect(LaunchpadStageView.footer(for: flow).showsBack == false)
        primary.action()
        #expect(flow.step == .found)
    }

    /// The library waits for the last app's read: with Codex and Claude Code
    /// read and Gemini CLI still reading, nothing is written; once Gemini
    /// CLI lands, the library is made from all three.
    @Test func theLibraryWaitsForTheLastAppsRead() async throws {
        let gates: [ClientKind: GatedCommandRunner] = [.codex: .init(), .claude: .init(), .gemini: .init()]
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let held = gates.mapValues { ScriptedFirstRead(observations: fixture.observations, gate: $0) }
        let flow = try toTheRead(
            fixture,
            change: { environment in
                let quick = fixture.firstReads
                environment.firstRead = { client, manifest in (held[client] ?? quick).reading(client, manifest: manifest) }
            })
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        for gate in gates.values { await gate.waitUntilCalled() }
        gates[.codex]?.release()
        gates[.claude]?.release()
        await waitUntil { read.observation(for: .codex) != nil && read.observation(for: .claude) != nil }
        await waitUntil { read.projectFolderCount != nil }

        #expect(read.phase == .reading)
        #expect(!read.isComplete)
        #expect(!fixture.hasWorkspace)
        #expect(flow.workspace == nil)

        gates[.gemini]?.release()
        await waitUntil { read.phase == .finished }
        #expect(fixture.hasWorkspace)
        #expect(flow.workspace?.device.observations.compactMap(\.surface.client) == [.claude, .codex, .gemini])
    }

    /// Stop ends every read and keeps nothing: the support folder is exactly
    /// as it was, with no library, no record and no locator.
    @Test func stopLeavesTheSupportFolderAsItWas() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)
        let before = try contents(of: fixture.support)

        start(flow)
        await gate.waitUntilCalled(times: 3)
        await read.stop()

        #expect(read.phase == .idle)
        #expect(!read.isStopping)
        #expect(gate.cancelledCalls == 3)
        #expect(try contents(of: fixture.support) == before)
        #expect(!fixture.hasWorkspace)
        #expect(flow.workspace == nil)
        #expect(flow.outcomes.read == nil)
        #expect(read.apps.isEmpty)
        #expect(read.placesRead.isEmpty)
        #expect(read.signIn.observations.isEmpty)
        #expect(LaunchpadTileSequenceScreen.face(flow) == .consent)
        #expect(read.spoken.last == "Reading stopped. Nothing was kept.")
    }

    /// ⎋ while reading is the footer's Stop.
    @Test func escapeWhileReadingStops() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)
        start(flow)
        await gate.waitUntilCalled(times: 3)

        flow.escape()
        await waitUntil { read.phase == .idle && !read.isStopping }

        #expect(!flow.isConfirmingLeave)
        #expect(!fixture.hasWorkspace)
    }

    /// A quit while reading stops the read, keeping nothing.
    @Test func aQuitWhileReadingStopsTheRead() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        start(flow)
        await gate.waitUntilCalled(times: 3)
        #expect(flow.interruption == .stoppable)

        await flow.prepareToQuit()

        #expect(LaunchpadReadSession.of(flow).phase == .idle)
        #expect(gate.cancelledCalls == 3)
        #expect(!fixture.hasWorkspace)
    }

    /// A quit right after the library is made stops the sign-in reads the
    /// commit did not wait for, so no command they started outlives the app.
    @Test func aQuitAfterTheCommitStopsTheSignInReads() async throws {
        let signInGate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(signInGate: signInGate)
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)
        start(flow)
        await waitUntil { read.phase == .finished }
        await signInGate.waitUntilCalled(times: 2)
        #expect(read.interruption == .stoppable)
        #expect(flow.interruption == .stoppable)

        await flow.prepareToQuit()
        await waitUntil { signInGate.cancelledCalls == 2 }

        #expect(read.signIn.isFinished)
        #expect(read.interruption == .idle)
        #expect(flow.interruption == .idle)
        // The library stays as it was made.
        #expect(read.phase == .finished)
        #expect(fixture.hasWorkspace)
    }

    // MARK: - Skip

    /// Skip this app stops that app's read and its sign-in read; the others
    /// carry on, and the library is made from what was read. The skipped
    /// app has no observation, so it reads "Not checked yet".
    @Test func skipStopsThatAppAndItsSignIn() async throws {
        let codexGate = GatedCommandRunner()
        let signInGate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(signInGate: signInGate)
        defer { fixture.remove() }
        let held = ScriptedFirstRead(observations: fixture.observations, gate: codexGate)
        let flow = try toTheRead(
            fixture,
            change: { environment in
                let quick = fixture.firstReads
                environment.firstRead = { client, manifest in
                    client == .codex ? held.reading(client, manifest: manifest) : quick.reading(client, manifest: manifest)
                }
            })
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await codexGate.waitUntilCalled()
        await waitUntil { read.observation(for: .claude) != nil && read.observation(for: .gemini) != nil }
        await signInGate.waitUntilCalled(times: 2)
        #expect(read.signIn.reading == [.chatGPT, .claude])
        #expect(!fixture.hasWorkspace)

        read.skip(.codex, flow: flow)

        #expect(read.apps[.codex] == .skipped)
        #expect(read.signIn.reading == [.claude])
        await waitUntil { read.phase == .finished }
        #expect(codexGate.cancelledCalls == 1)
        let workspace = try #require(flow.workspace)
        #expect(workspace.device.observations.compactMap(\.surface.client) == [.claude, .gemini])
        #expect(workspace.device.verdict(for: .codex).text == "Not checked yet")
        // Codex is still this Mac's: skipped, never turned off.
        #expect(workspace.device.managedClients == [.codex, .claude, .gemini])
        #expect(flow.outcomes.read?.skipped == [.codex])
        #expect(read.versionLine(for: .codex) == "Not checked yet")
        #expect(read.spoken.contains("Codex skipped. Nothing of it is kept."))

        signInGate.release()
        await read.signIn.waitUntilFinished()
        #expect(read.signIn.observations.keys.sorted() == [.claude])
    }

    /// Skipping Claude Code lets go of the folder names in its history too:
    /// they are not counted, not ticked and not kept for Home.
    @Test func skippingClaudeCodeLetsGoOfItsProjects() async throws {
        let claudeGate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let held = ScriptedFirstRead(observations: fixture.observations, gate: claudeGate)
        let flow = try toTheRead(
            fixture,
            change: { environment in
                let quick = fixture.firstReads
                environment.firstRead = { client, manifest in
                    client == .claude ? held.reading(client, manifest: manifest) : quick.reading(client, manifest: manifest)
                }
            })
        let read = LaunchpadReadSession.of(flow)
        let manifest = LaunchpadReadSession.plannedManifest(for: flow)
        let history = try #require(manifest.apps.flatMap(\.places).first { $0.role == .projectHistory })

        start(flow)
        await claudeGate.waitUntilCalled()
        await waitUntil { read.projectFolderCount != nil }
        #expect(read.projectFolderCount == 4)
        #expect(read.placesRead.contains(history.id))

        read.skip(.claude, flow: flow)

        #expect(read.projectFolderCount == nil)
        #expect(!read.placesRead.contains(history.id))
        await waitUntil { read.phase == .finished }
        let workspace = try #require(flow.workspace)
        #expect(read.projectFolderCount == nil)
        #expect(fixture.savedRecord(for: workspace)?.evidence.projectFolderCount == nil)
        #expect(flow.outcomes.read?.skipped == [.claude])
        #expect(claudeGate.cancelledCalls == 1)
    }

    // MARK: - Late events

    /// What a read reports after it was stopped belongs to a read that no
    /// longer exists and changes nothing, even when the next read is under
    /// way.
    @Test func lateEventsAfterStopAreDropped() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let streams = HeldStreams()
        let flow = try toTheRead(
            fixture,
            change: { environment in
                environment.firstRead = { client, _ in streams.reading(client) }
            })
        let read = LaunchpadReadSession.of(flow)
        let manifest = LaunchpadReadSession.plannedManifest(for: flow)
        let codexPlaces = try #require(manifest.apps.first { $0.client == .codex }?.places)

        start(flow)
        let first = streams.continuations
        #expect(first.count == 3)
        await read.stop()
        // The stopped read keeps talking.
        first[.codex]?.yield(.placeRead(.codex, codexPlaces[0].id))
        first[.codex]?.yield(.finished(try #require(fixture.observations[.codex])))

        start(flow)
        let second = streams.continuations
        second[.codex]?.yield(.placeRead(.codex, codexPlaces[1].id))
        await waitUntil { read.placesRead.contains(codexPlaces[1].id) }
        first[.codex]?.yield(.placeRead(.codex, codexPlaces[2].id))
        second[.codex]?.yield(.placeRead(.codex, codexPlaces[3].id))
        await waitUntil { read.placesRead.contains(codexPlaces[3].id) }

        #expect(read.placesRead.intersection(codexPlaces.map(\.id)) == [codexPlaces[1].id, codexPlaces[3].id])
        #expect(read.observation(for: .codex) == nil)
        #expect(!fixture.hasWorkspace)
        await read.stop()
    }

    // MARK: - Notices

    /// Past ten seconds a read says it is taking a while and can be skipped;
    /// past a minute it says its files were read from disk only. The first
    /// app in the app order speaks.
    @Test func slowReadsRaiseTheirNoticesInTime() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let clock = TestClock()
        clock.now = 100
        let flow = try toTheRead(
            fixture,
            prepare: { flow in
                _ = flow.model(for: .reads) { LaunchpadReadSession(environment: flow.environment, clock: { clock.now }) }
            })
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await gate.waitUntilCalled(times: 3)

        #expect(read.notice(now: 105) == nil)
        let slow = try #require(read.notice(now: 110))
        #expect(slow == .slow(.codex))
        #expect(slow.canSkip)
        #expect(LaunchpadReadSession.text(of: slow) == "Codex is taking a while (up to a minute).")
        #expect(read.elapsed(for: .claude, now: 112.5) == 12.5)
        let unanswered = try #require(read.notice(now: 160))
        #expect(unanswered == .unanswered(.codex))
        #expect(!unanswered.canSkip)
        #expect(LaunchpadReadSession.text(of: unanswered) == "Codex did not answer in a minute. Its files were read from disk only.")

        read.skip(.codex, flow: flow)
        #expect(read.notice(now: 110) == .slow(.claude))
        await read.stop()
    }

    /// A `--version` that ran out of time leaves the app found with its
    /// version unknown, and says installs into it wait.
    @Test func aHungVersionSaysInstallsWait() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        var codex = try #require(fixture.observations[.codex])
        codex.version = nil
        let hung = codex
        let flow = try toTheRead(
            fixture,
            change: { environment in
                let quick = fixture.firstReads
                environment.firstRead = { client, manifest in
                    guard client == .codex else { return quick.reading(client, manifest: manifest) }
                    let version = manifest.apps.first { $0.client == .codex }?.commands.first
                    let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
                    if let version {
                        continuation.yield(.commandStarted(.codex, version.id))
                        continuation.yield(.commandFinished(.codex, version.id, .timedOut))
                    }
                    continuation.yield(.finished(hung))
                    continuation.finish()
                    return FirstRead.Reading(events)
                }
            })
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await waitUntil { read.phase == .finished }

        #expect(read.versionLine(for: .codex) == "Version unknown")
        let notice = try #require(read.notice(now: read.now()))
        #expect(notice == .versionUnanswered(.codex))
        #expect(LaunchpadReadSession.text(of: notice) == "Codex did not answer --version. Installs into it wait until it does.")
        #expect(read.spoken.contains("Codex read: version unknown, 2 skills, 1 plugin, 1 connection."))
    }

    // MARK: - What the commit records

    /// The library is made from exactly what was read, with this Mac's
    /// choices in revision 1: the apps chosen, the folders the login shell
    /// found, the projects choice, every assistant run off.
    @Test func theCommitSeedsThisMacsChoices() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        flow.seedOverride = LaunchpadSeed(
            chosen: [.codex, .claude, .gemini], toolDirectories: ["/opt/tools/bin"], findsProjectsFromClaudeHistory: false)
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await waitUntil { read.phase == .finished }

        let workspace = try #require(flow.workspace)
        let snapshot = try #require(try workspace.store.snapshot())
        let preferences = try #require(snapshot.device.applicationState?.preferences)
        #expect(Set(preferences.chosenClients ?? []) == [.codex, .claude, .gemini])
        #expect(preferences.customToolDirectories == ["/opt/tools/bin"])
        #expect(preferences.findsProjectsFromClaudeHistory == false)
        #expect(preferences.assistantRuns == .off)
        #expect(snapshot.device.observations.count == 3)
        // Revision 1, the first: nothing was written after it.
        #expect(snapshot.document.revision.parentIDs.isEmpty)
        // With the projects choice off, nothing of Claude Code's history was
        // listed, and there is no count to keep.
        #expect(read.projectFolderCount == nil)
        #expect(fixture.savedRecord(for: workspace)?.evidence.projectFolderCount == nil)
        #expect(fixture.observer.fullChecks == 0)
    }

    /// With the projects choice on, the folder names in Claude Code's
    /// history are listed (and only listed), and the count is kept for
    /// Home's card.
    @Test func theProjectFolderCountIsKeptForHome() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await waitUntil { read.phase == .finished }

        #expect(read.projectFolderCount == 4)
        let workspace = try #require(flow.workspace)
        #expect(fixture.savedRecord(for: workspace)?.evidence.projectFolderCount == 4)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .found)
    }

    /// The sample world reads 14 places and runs 9 commands in the public
    /// build, every one of them, and changes nothing in the apps. Done is
    /// told what was read.
    @Test func theSampleWorldReads14PlacesAnd9Commands() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await waitUntil { read.phase == .finished }
        await read.signIn.waitUntilFinished()
        await waitUntil { flow.outcomes.read?.commands == 9 }

        #expect(read.placeTotal == 14)
        #expect(read.commandTotal == 9)
        #expect(read.placesRead.count == 14)
        #expect(read.commandsRun.count == 9)
        #expect(read.finalTally == "14 places read · 9 commands run · 0 changed in your apps")
        let summary = try #require(flow.outcomes.read)
        #expect(summary.places == 14)
        #expect(summary.commands == 9)
        #expect(summary.looked.map(\.client) == [.codex, .claude, .gemini])
        #expect(summary.looked.map(\.version) == ["0.164.0", "2.1.304", "0.38.2"])
        #expect(summary.notFound == [.kiro])
        #expect(summary.skipped.isEmpty)
        // Nothing in any app was run that was not on the list.
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.observer.scopedChecks.isEmpty)
    }

    /// D35: the commit never waits for the sign-in read. When it lands it
    /// joins the library's accounts, and the stage audit runs again, still
    /// without reading any account itself.
    @Test func theCommitDoesNotWaitForTheSignInRead() async throws {
        let signInGate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(signInGate: signInGate)
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await waitUntil { read.phase == .finished }

        let workspace = try #require(flow.workspace)
        #expect(!read.signIn.isFinished)
        #expect(workspace.accounts.observations.isEmpty)
        let firstAudit = try #require(workspace.setup.checkup?.audit.generatedAt)
        #expect(read.commandsRun.count == 6)

        signInGate.release()
        await waitUntil { workspace.accounts.observations.count == 2 }
        #expect(Set(workspace.accounts.observations.keys) == [.chatGPT, .claude])
        await waitUntil { flow.outcomes.read?.commands == 9 }
        // The stage audit ran again, now with the sign-ins.
        await waitUntil { workspace.setup.checkup?.audit.generatedAt != firstAudit }
        // The one login-shell probe was the sign-in read's own.
        #expect(fixture.signIn.shellProbes == 1)
    }

    /// "0 changed in your apps" is a fact: the read, the commit and the
    /// stage audits leave every file in the home folder as it was.
    @Test func theReadAndTheCommitChangeNothingInTheHome() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)
        let before = try files(in: fixture.home)

        start(flow)
        await waitUntil { read.phase == .finished }
        await read.signIn.waitUntilFinished()
        await waitUntil { flow.outcomes.read?.commands == 9 }

        #expect(before.count > 20)
        #expect(try files(in: fixture.home) == before)
    }

    /// Leaving once the library holds the read (⎋, then Go to Home) leaves
    /// the walk for later where it stands: Your library, the cursor the
    /// commit wrote, never back at the read it would only redo.
    @Test func leavingAfterTheReadKeepsTheCursorAtYourLibrary() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)
        start(flow)
        await waitUntil { read.phase == .finished }
        let workspace = try #require(flow.workspace)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .found)

        flow.escape()
        #expect(flow.isConfirmingLeave)
        #expect(flow.leaveMoment == .afterCommit)
        flow.leave()

        #expect(flow.pendingHandOff == .overview)
        #expect(fixture.savedRecord(for: workspace)?.state == .deferred)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .found)
    }

    /// A rerun writes its record only at Done (D20), so its project-folder
    /// count stays on the read for Done to hand to `flow.finish(evidence:)`:
    /// nothing is recorded before.
    @Test func aRerunKeepsItsProjectCountForDone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let before = fixture.savedRecord(for: workspace)
        let flow = fixture.flow(.rerun, workspace: workspace)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await waitUntil { read.phase == .finished }

        #expect(read.projectFolderCount == 4)
        #expect(fixture.savedRecord(for: workspace) == before)
        // What Done hands over.
        var evidence = before?.evidence ?? SetupProgressRecord.Evidence()
        evidence.projectFolderCount = read.projectFolderCount
        flow.finish(handOffTo: .overview, evidence: evidence)
        #expect(fixture.savedRecord(for: workspace)?.evidence.projectFolderCount == 4)
    }

    /// A rerun's read updates the library that is there: nothing is
    /// created, this Mac's check is the read, and its record is not written
    /// until Done.
    @Test func aRerunsReadAdopts() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let containers = try contents(of: fixture.support.appending(path: "workspaces-v1", directoryHint: .isDirectory))
        let before = fixture.savedRecord(for: workspace)
        let flow = fixture.flow(.rerun, workspace: workspace)
        LaunchpadStageView.footer(for: flow).primary?.action()
        #expect(flow.step == .reads)
        let read = LaunchpadReadSession.of(flow)
        #expect(
            LaunchpadTileSequenceScreen.subtitle(.consent, flow: flow, read: read).hasSuffix(
                "Your library is updated last, from what this reads. Chat history is not read here."))

        start(flow)
        #expect(read.updatesLibrary)
        #expect(read.interruption == .stoppable)
        await waitUntil { read.phase == .finished }

        #expect(flow.workspace?.store.databaseURL == workspace.store.databaseURL)
        #expect(try contents(of: fixture.support.appending(path: "workspaces-v1", directoryHint: .isDirectory)) == containers)
        #expect(fixture.firstReads.started == [.codex, .claude, .gemini])
        #expect(workspace.device.observations.count == 3)
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.savedRecord(for: workspace) == before)
        #expect(read.spoken.last == "Reading finished. Your library is up to date.")
    }

    /// A library that cannot be made says so and changes nothing; Try again
    /// makes it from the same read, reading nothing again.
    @Test func aFailedCommitCanBeTriedAgain() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)
        start(flow)
        await gate.waitUntilCalled(times: 3)
        // Something else put a record there meanwhile, one this build cannot
        // read: the library is not made over it.
        let locator = fixture.support.appending(path: "workspace.json")
        try Data("{".utf8).write(to: locator)
        gate.release()
        await waitUntil { read.failure != nil }

        #expect(read.failure == "Your library could not be created. Nothing was changed.")
        #expect(read.spoken.last == read.failure)
        #expect(flow.workspace == nil)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Try again")

        try FileManager.default.removeItem(at: locator)
        primary.action()
        await waitUntil { read.phase == .finished }
        #expect(flow.workspace != nil)
        #expect(fixture.firstReads.started.count == 3)
    }

    /// Back to Your apps after the library could not be made: the reason
    /// stays in view, the primary still works, and it lets the failed read
    /// go, so the walk reads again from the choice made there.
    @Test func backAfterAFailedCommitReadsAgain() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = try toTheRead(fixture)
        let read = LaunchpadReadSession.of(flow)
        let locator = fixture.support.appending(path: "workspace.json")
        try Data("{".utf8).write(to: locator)
        start(flow)
        await waitUntil { read.failure != nil }

        flow.goBack()
        #expect(flow.step == .apps)
        #expect(LaunchpadTileSequenceScreen.face(flow) == .apps)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Manage 3 apps")
        #expect(primary.isEnabled)

        try FileManager.default.removeItem(at: locator)
        primary.action()
        #expect(read.phase == .idle)
        #expect(read.failure == nil)
        #expect(LaunchpadTileSequenceScreen.face(flow) == .consent)
        start(flow)
        await waitUntil { read.phase == .finished }
        #expect(flow.workspace != nil)
        #expect(fixture.firstReads.started.count == 6)
    }

    /// Continue without apps whose library could not be made stays on the
    /// empty Mac, saying why; pressing it again makes the library and goes
    /// on to the catalogs.
    @Test func anEmptyLibraryThatCouldNotBeMadeIsTriedAgain() async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        let read = LaunchpadReadSession.of(flow)
        let locator = fixture.support.appending(path: "workspace.json")
        try Data("{".utf8).write(to: locator)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.failure != nil }

        #expect(flow.step == .apps)
        #expect(flow.workspace == nil)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.title == "Continue without apps")
        #expect(primary.isEnabled)

        try FileManager.default.removeItem(at: locator)
        primary.action()
        await waitUntil { flow.step == .library }
        #expect(flow.workspace != nil)
        #expect(fixture.firstReads.started.isEmpty)
    }

    // MARK: - V2

    /// An app too old to read its account says to update it instead of what
    /// it could not read. Unknown versions, and apps with no minimum, never
    /// do.
    @Test func anAppTooOldToReadItsAccountSaysToUpdate() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        var codex = try #require(fixture.observations[.codex])
        var claude = try #require(fixture.observations[.claude])
        var gemini = try #require(fixture.observations[.gemini])
        #expect(LaunchpadReadSession.accountReaderLine(for: .codex, observation: codex) == nil)
        #expect(LaunchpadReadSession.accountReaderLine(for: .claude, observation: claude) == nil)

        codex.version = "codex-cli 0.150.0"
        claude.version = "2.1.250 (Claude Code)"
        gemini.version = "0.1.0"
        #expect(
            LaunchpadReadSession.accountReaderLine(for: .codex, observation: codex)
                == "Update Codex to read your ChatGPT account here")
        #expect(
            LaunchpadReadSession.accountReaderLine(for: .claude, observation: claude)
                == "Update Claude Code to read your claude.ai account here")
        #expect(LaunchpadReadSession.accountReaderLine(for: .gemini, observation: gemini) == nil)
        codex.version = "nightly"
        #expect(LaunchpadReadSession.accountReaderLine(for: .codex, observation: codex) == nil)
    }

    /// V2 on the read: an app too old to read its account says so under
    /// the tally once it is read.
    @Test func anOutdatedAppRaisesItsNotice() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        var codex = try #require(fixture.observations[.codex])
        codex.version = "codex-cli 0.150.0"
        let old = codex
        let flow = try toTheRead(
            fixture,
            change: { environment in
                let quick = fixture.firstReads
                environment.firstRead = { client, manifest in
                    guard client == .codex else { return quick.reading(client, manifest: manifest) }
                    let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
                    continuation.yield(.finished(old))
                    continuation.finish()
                    return FirstRead.Reading(events)
                }
            })
        let read = LaunchpadReadSession.of(flow)

        start(flow)
        await waitUntil { read.phase == .finished }

        let notice = try #require(read.notice(now: read.now()))
        #expect(notice == .outdated(.codex))
        #expect(!notice.canSkip)
        #expect(LaunchpadReadSession.text(of: notice) == "Update Codex to read your ChatGPT account here.")
    }

    // MARK: - Helpers

    /// A first run walked to What Agent Tooling reads, its environment
    /// changed first by `change`.
    private func toTheRead(
        _ fixture: LaunchpadFixture, change: (inout LaunchpadEnvironment) -> Void = { _ in },
        prepare: (LaunchpadFlow) -> Void = { _ in }
    ) throws -> LaunchpadFlow {
        var environment = fixture.environment
        change(&environment)
        let flow = LaunchpadFlow(entry: .firstRun, environment: environment)
        prepare(flow)
        flow.choosePath(.startHere)
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        primary.action()
        #expect(flow.step == .reads)
        return flow
    }

    /// Continue on What Agent Tooling reads.
    private func start(_ flow: LaunchpadFlow) {
        LaunchpadStageView.footer(for: flow).primary?.action()
    }

    /// Every file under `folder`, hidden ones too, relative to it, with its
    /// size and when it last changed.
    private func files(in folder: URL) throws -> [String: String] {
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [:] }
        var found: [String: String] = [:]
        for case let file as URL in walk {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path(percentEncoded: false)
            let changed = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            found[String(path.dropFirst(root.count))] = "\(values.fileSize ?? 0) bytes, changed \(changed)"
        }
        return found
    }

    /// Every path under `folder`, relative to it.
    private func contents(of folder: URL) throws -> Set<String> {
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        guard let walk = FileManager.default.enumerator(atPath: root) else { return [] }
        return Set(walk.compactMap { $0 as? String })
    }
}

/// A clock a test sets by hand.
@MainActor
private final class TestClock {
    var now: TimeInterval = 0
}

/// Readings whose events the test sends, and which keep talking after they
/// are stopped, as a misbehaving read might.
private final class HeldStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [ClientKind: AsyncStream<FirstRead.Event>.Continuation] = [:]

    /// The latest reading's continuation for each app.
    var continuations: [ClientKind: AsyncStream<FirstRead.Event>.Continuation] { lock.withLock { held } }

    func reading(_ client: ClientKind) -> FirstRead.Reading {
        let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        lock.withLock { held[client] = continuation }
        return FirstRead.Reading(events)
    }
}
