import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Your library, as read (S06), on the sample world: each app's version and
/// holdings, the entries the library holds with the marks of the apps that
/// hold them, how a skill's copies compare, the stage audit's count, and
/// that nothing the read saw went unrecorded.
@Suite("Launchpad found", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadFoundTests {
    /// The eight entries, skills then plugins then connections, each with
    /// the apps that hold it, its detail and whose it is.
    @Test func theEightEntriesCarryTheMarksTheReadFound() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let rows = try Self.rows(of: workspace)

        let expected: [(String, [ClientKind], String?, String)] = [
            ("Frontend Design", [.codex, .claude, .gemini], "2 copies · 2 versions", "Unmanaged"),
            ("Webapp Testing", [.codex, .claude], "2 copies · same content", "Unmanaged"),
            ("Release Notes", [.claude], "Only in Claude Code", "Unmanaged"),
            ("GitHub", [.claude], "Includes 1 connection", "Managed by its app"),
            ("Linear", [.codex], nil, "Managed by its app"),
            ("Sentry", [.claude], "Includes 1 skill · 1 connection", "Managed by its app"),
            ("Context7", [.claude, .gemini], "Configured in 2 apps", "Unmanaged"),
            ("Playwright", [.codex, .claude], "Configured in 2 apps", "Unmanaged"),
        ]
        #expect(rows.count == 8)
        for (row, (name, apps, detail, ownership)) in zip(rows, expected) {
            #expect(row.name == name)
            #expect(row.apps == apps, "\(name)")
            #expect(row.detailText == detail, "\(name)")
            #expect(row.ownership == ownership, "\(name)")
        }
        #expect(rows[0].copiesDiffer)
        #expect(!rows[1].copiesDiffer)
        #expect(rows.map(\.kind) == [.skill, .skill, .skill, .nativePlugin, .nativePlugin, .nativePlugin, .mcpServer, .mcpServer])
    }

    /// The list fills its first column, then its second.
    @Test func theListFillsDownItsFirstColumn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let rows = try Self.rows(of: workspace)

        let columns = LibraryRowPresence.columns(rows)
        #expect(columns.leading.map(\.name) == ["Frontend Design", "Webapp Testing", "Release Notes", "GitHub"])
        #expect(columns.trailing.map(\.name) == ["Linear", "Sentry", "Context7", "Playwright"])
        let odd = LibraryRowPresence.columns(Array(rows.prefix(5)))
        #expect(odd.leading.count == 3)
        #expect(odd.trailing.count == 2)
    }

    /// The tiles: 0.164.0, 2.1.304 and 0.38.2, and what each app's read
    /// found, in the Library's nouns.
    @Test func eachReadAppsVersionAndHoldings() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let observations = Dictionary(
            uniqueKeysWithValues: workspace.device.observations.compactMap { observation in
                observation.surface.client.map { ($0, observation) }
            })

        #expect(
            [ClientKind.codex, .claude, .gemini].map { ClientVersionText.number(in: observations[$0]?.version) }
                == ["0.164.0", "2.1.304", "0.38.2"])
        #expect(
            [ClientKind.codex, .claude, .gemini].compactMap { observations[$0].map(LibraryRowPresence.holdings(of:))?.summary }
                == ["2 skills · 1 plugin · 1 connection", "4 skills · 2 plugins · 4 connections", "1 skill · 0 plugins · 1 connection"])
        #expect(workspace.library.state?.library.holdingsSentence == "It holds 11 tools. 3 of them come inside plugins.")
    }

    /// A skill's copies are the folders the managed apps read it from, with
    /// who reads each, and how many files each holds once measured.
    @Test func aSkillsCopiesAreItsFolders() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let frontend = try #require(try Self.rows(of: workspace).first { $0.name == "Frontend Design" })

        let measured = await LibraryRowPresence.measured(frontend.copies)
        let home = fixture.home
        #expect(
            measured.map { PathDisplay.abbreviatingHome($0.path, home: home) } == [
                "~/.agents/skills/frontend-design", "~/.claude/skills/frontend-design",
            ])
        #expect(measured.map(\.readers) == [[.codex, .gemini], [.claude]])
        #expect(measured.map(\.fileCount) == [2, 3])
    }

    /// Only the apps this Mac manages are marked: with Gemini CLI turned
    /// off its slot is gone, and so is its copy's reader.
    @Test func onlyTheManagedAppsAreMarked() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let state = try #require(workspace.library.state)

        let rows = LibraryRowPresence.rows(in: state, observations: workspace.device.observations, managed: [.codex, .claude])

        let frontend = try #require(rows.first { $0.name == "Frontend Design" })
        #expect(frontend.apps == [.codex, .claude])
        #expect(frontend.copies.map(\.readers) == [[.codex], [.claude]])
        let context7 = try #require(rows.first { $0.name == "Context7" })
        #expect(context7.apps == [.claude])
        #expect(context7.detailText == "Only in Claude Code")
    }

    @Test func sampleMCPCommandsAreReachableWithoutHostTools() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let tools = fixture.home.appending(path: ".local/bin", directoryHint: .isDirectory)
        let auditor = SetupAuditor(homeURL: fixture.home, searchPath: [tools])
        let clients = ClientKind.allCases.filter { fixture.world.found.contains($0) }
        let facts = SetupAuditor.LibraryFacts(managedSkillNames: [])
        let present = auditor.audit(observations: fixture.orderedObservations, managed: clients, library: facts)
        #expect(!present.findings.contains { $0.kind == .unreachableMCPCommand })

        try FileManager.default.removeItem(at: tools.appending(path: "npx"))
        let missing = auditor.audit(observations: fixture.orderedObservations, managed: clients, library: facts)
        let commands = missing.findings.filter { $0.kind == .unreachableMCPCommand }
        #expect(Set(commands.compactMap(\.client)) == [.codex, .claude])
        #expect(commands.allSatisfy { $0.subject == "playwright" })
    }

    /// "8 things to look at" is the stage audit's open findings and
    /// recommendations; a difference from another Mac's accounts is never
    /// one of them on the stage (D34).
    ///
    /// The sample world has 8: six unmanaged skills, and Context7 and
    /// Playwright each configured by hand in two apps. Codex lists
    /// Playwright twice over, in config.toml and in its own `mcp list`;
    /// that is one definition, still the one configured by hand, so it is
    /// counted among Playwright's two apps.
    @Test func thingsToLookAtCountTheStageAudit() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let checkup = try #require(workspace.setup.checkup)
        let count = LibraryRowPresence.thingsToLookAt(checkup)

        #expect(count == checkup.openFindings.count + checkup.openRecommendations.count)
        #expect(count == 8)
        #expect(checkup.openFindings.filter { $0.kind == .unmanagedSkill }.count == 6)
        #expect(
            checkup.openFindings.filter { $0.kind == .mcpServerRepeatedAcrossClients }.map(\.subject).sorted()
                == ["context7", "playwright"])
        #expect(!checkup.openFindings.contains { $0.kind == .mcpServerDefinedSeveralTimes })
        #expect(LibraryRowPresence.thingsToLookAt(nil) == nil)

        var differing = checkup
        differing.audit.findings.append(
            SetupFinding(
                kind: .accountDiffersFromOtherMacs, severity: .high, client: .claude, subject: "claude",
                title: "Accounts differ", detail: "Another Mac signs in differently.", evidence: [], actions: []))
        #expect(LibraryRowPresence.thingsToLookAt(differing) == count)
        #expect(LaunchpadCopy.Found.thingsToLookAt(7) == "7 things to look at, later on Checkup")
        #expect(LaunchpadCopy.Found.thingsToLookAt(1) == "1 thing to look at, later on Checkup")
        #expect(LaunchpadCopy.Found.thingsToLookAt(0) == "Nothing to look at on Checkup")
    }

    /// Everything Juniper's read saw is in the library, so "Not recorded,
    /// and why" does not show.
    @Test func nothingTheReadSawWentUnrecorded() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let document = try #require(workspace.library.state?.snapshot.document)

        let skipped = await LibraryRowPresence.notRecorded(
            document: document, observations: workspace.device.observations, homeURL: fixture.home)

        #expect(skipped.isEmpty)
    }

    /// A skill its package owns but whose place inside the package the read
    /// could not say is left out of the library, and the read says why, in
    /// the reconciliation's own words after the skill's name.
    @Test func aSkillTheReadCouldNotPlaceIsSaidToBeUnrecorded() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let document = try #require(workspace.library.state?.snapshot.document)
        var claude = try #require(workspace.device.observations.first { $0.surface == .claudeCode })
        claude.discoveredSkills.append("sentry:loose-notes")
        claude.skillMetadata["sentry:loose-notes"] = ObservedSkillMetadata(
            path: fixture.home.appending(path: "elsewhere/loose-notes/").path(percentEncoded: false), source: "Claude Code",
            providerPluginID: "sentry@claude-plugins-official")
        let observations = workspace.device.observations.map { $0.surface == .claudeCode ? claude : $0 }

        let skipped = await LibraryRowPresence.notRecorded(document: document, observations: observations, homeURL: fixture.home)

        // Named as a person knows it, not by the identifier Claude Code
        // reports.
        #expect(skipped == ["Loose Notes: its package owns it, but the check could not say where inside it."])
    }

    /// D10: Agent Tooling's own connection is bound to each Mac, so it is
    /// never one of the library's entries or an app's holdings. After the
    /// install it is registered in Codex and Claude Code; a rerun's Your
    /// library leaves it out of the list, the tiles and what VoiceOver
    /// hears.
    @Test func agentToolingsOwnConnectionIsNoEntryAndNoHolding() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterInstall)
        let flow = fixture.flow(.rerun, workspace: sample.workspace)
        flow.go(to: .found)
        #expect(LaunchpadTileSequenceScreen.face(flow) == .found)
        let workspace = try #require(flow.workspace)
        let state = try #require(workspace.library.state)
        let helper = try #require(sample.artifact(AgentToolingConnection.declaredName))
        #expect(LibraryRowPresence.ownConnections(in: state.snapshot.document) == [helper.identity.id])
        #expect(state.library.rows.contains { $0.artifactID == helper.identity.id })

        let rows = LibraryRowPresence.rows(
            in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)
        #expect(!rows.contains { $0.declaredName == AgentToolingConnection.declaredName })
        #expect(rows.count == state.library.rows.count - 1)
        let observations = Dictionary(
            uniqueKeysWithValues: workspace.device.observations.compactMap { observation in
                observation.surface.client.map { ($0, observation) }
            })
        let codex = try #require(observations[.codex])
        let claude = try #require(observations[.claude])
        #expect(codex.discoveredMCPServers.contains(AgentToolingConnection.declaredName))
        #expect(claude.discoveredMCPServers.contains(AgentToolingConnection.declaredName))
        #expect(LibraryRowPresence.holdings(of: codex).summary == "3 skills · 1 plugin · 1 connection")
        #expect(LibraryRowPresence.holdings(of: claude).summary == "4 skills · 3 plugins · 4 connections")
        #expect(
            LaunchpadReadSession.readAnnouncement(for: .codex, observation: codex)
                == "Codex read: version 0.164.0, 3 skills, 1 plugin, 1 connection.")
    }

    /// ↑↓ moves the keyboard's place down the first column, then the
    /// second: the first press lands on the first entry, and either end
    /// holds. A click moves it too. The flow keeps it.
    @Test func theKeyboardsPlaceRunsDownTheColumns() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterRead)
        let columns = LibraryRowPresence.columns(try Self.rows(of: sample.workspace))
        let ordered = columns.leading + columns.trailing
        let highlight = LaunchpadFoundHighlight.of(flow)
        #expect(highlight.row == nil)

        highlight.move(by: -1, in: ordered)
        #expect(highlight.row == ordered[0].id)
        for _ in 0..<9 { highlight.move(by: 1, in: ordered) }
        #expect(highlight.row == ordered[7].id)
        #expect(ordered[3].name == "GitHub")
        #expect(ordered[4].name == "Linear")
        highlight.move(by: -1, in: ordered)
        #expect(highlight.row == ordered[6].id)
        highlight.select(ordered[2].id)
        #expect(highlight.row == ordered[2].id)
        highlight.move(by: 1, in: [])
        #expect(highlight.row == ordered[2].id)
        #expect(LaunchpadFoundHighlight.of(flow) === highlight)
    }

    /// S06 on the walk itself: the found face, its subtitle, and the tally
    /// as the read left it; a rerun drops "Nothing is installed or assigned
    /// yet." and says the library is up to date.
    @Test func theFoundFaceOnTheWalk() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .finished }
        await read.signIn.waitUntilFinished()
        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.step == .found)
        #expect(LaunchpadTileSequenceScreen.face(flow) == .found)
        #expect(
            LaunchpadTileSequenceScreen.subtitle(.found, flow: flow, read: read)
                == "It holds 11 tools. 3 of them come inside plugins. Nothing is installed or assigned yet.")
        let figures = try #require(LaunchpadTileSequenceScreen.foundFigures(flow, read: read))
        #expect(figures.places == 14)
        #expect(figures.commands == 9)
        #expect(flow.info.back == nil)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == "Continue")

        let workspace = try #require(flow.workspace)
        let rerun = fixture.flow(.rerun, workspace: workspace)
        rerun.go(to: .found)
        #expect(
            LaunchpadTileSequenceScreen.subtitle(.found, flow: rerun, read: LaunchpadReadSession.of(rerun))
                == "It holds 11 tools. 3 of them come inside plugins.")
    }

    /// The tile a read app draws on each face: managed and lit on Your
    /// apps, a spinner while it is read, a green check once read; an app
    /// turned off is a ghost, one not found a socket.
    @Test func eachFacesTileStates() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let codex = try #require(fixture.observations[.codex])
        typealias Screen = LaunchpadTileSequenceScreen
        func state(_ face: Screen.Face, managed: Bool = true, found: Bool = true, read: LaunchpadReadSession.AppRead? = nil)
            -> StageAgentTile.State
        {
            Screen.tileState(face: face, managed: managed, found: found, isLit: true, read: read, observation: nil)
        }

        #expect(state(.apps) == .managed)
        #expect(state(.apps, managed: false) == .ghost)
        #expect(state(.apps, managed: false, found: false) == .absent)
        #expect(state(.apps, found: false) == .absentManaged)
        #expect(Screen.tileState(face: .apps, managed: true, found: true, isLit: false, read: nil, observation: nil) == .ghost)
        #expect(state(.consent) == .managed)
        #expect(state(.reading, read: .reading(since: 0)) == .reading)
        #expect(state(.reading, read: .read(codex, seconds: 1)) == .read)
        #expect(state(.reading, read: .skipped) == .managed)
        #expect(state(.reading, managed: false) == .ghost)
        #expect(Screen.tileState(face: .found, managed: true, found: true, isLit: true, read: nil, observation: codex) == .read)
        #expect(state(.found) == .managed)
        #expect(state(.found, managed: false) == .ghost)
        #expect(state(.found, managed: false, found: false) == .absent)
    }

    private static func rows(of workspace: WorkspaceLaunch.Workspace) throws -> [LibraryRowPresence] {
        let state = try #require(workspace.library.state)
        return LibraryRowPresence.rows(
            in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)
    }
}
