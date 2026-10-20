import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// What VoiceOver hears on Your apps, the read and what was found, computed
/// in the models so it is pinned here: the tile row's summary, each tile as
/// a toggle with its key, the detection announcement, one list per app with
/// its counts, the linked line, an announcement as each app is read and one
/// when the library is made, the tally read once with its final figures, and
/// each entry of the library in one sentence.
@Suite("Launchpad reads accessibility", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadReadsAccessibilityTests {
    @Test func theTileRowAndEachToggle() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let detection = LaunchpadDetection(environment: fixture.environment)

        #expect(detection.rowSummary == "Apps: Codex, Claude Code and Gemini CLI found; Kiro CLI not found")
        #expect(detection.tileLabel(.codex, managed: true) == "Codex, found at ~/.npm-global/bin/codex, managed")
        #expect(detection.tileLabel(.kiro, managed: false) == "Kiro CLI, not found, not managed")
        #expect(detection.tileLabel(.kiro, managed: true) == "Kiro CLI, not found, managed")
        #expect(LaunchpadDetection.tileHint(.codex, managed: true) == "Command-1 turns it off")
        #expect(LaunchpadDetection.tileHint(.kiro, managed: false) == "Command-4 turns it on")
        #expect(detection.foundAnnouncement == "Found 3 of 4 apps.")
        // The hint names the very key the tile binds.
        for client in ClientKind.allCases {
            let key = KeyCombo.spoken(LaunchpadTileSequenceScreen.tileShortcut(client))
            #expect(LaunchpadDetection.tileHint(client, managed: true).hasPrefix(key + " "))
        }
    }

    @Test func anEmptyMacsRow() async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let detection = LaunchpadDetection(environment: fixture.environment)

        #expect(detection.rowSummary == "Apps: Codex, Claude Code, Gemini CLI and Kiro CLI not found")
        #expect(detection.foundAnnouncement == "Found none of the 4 apps.")
    }

    /// One list per app: "Codex reads 4 places and runs 3 commands"; the
    /// place two apps read is said once, with Codex.
    @Test func oneListPerApp() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let manifest = FirstReadManifest.build(chosen: fixture.world.found, homeURL: fixture.home, includeProjectHistory: true)
        let summaries = manifest.apps.map { LaunchpadReadSession.manifestSummary(of: $0, home: fixture.home) }

        #expect(
            summaries == [
                "Codex reads 4 places and runs 3 commands", "Claude Code reads 5 places and runs 2 commands",
                "Gemini CLI reads 4 places, and ~/.agents/skills with Codex, and runs 1 command",
            ])
        let gemini = try #require(manifest.apps.last)
        let linked = try #require(gemini.places.first { $0.isLinked })
        let earlier = LaunchpadCopy.list(LaunchpadReadSession.earlierReaders(of: linked, in: gemini))
        #expect(LaunchpadCopy.Reads.linkedLabel(linked.display, apps: earlier) == "~/.agents/skills, also read for Codex")
    }

    /// Each app is announced as its read lands, then the library once it is
    /// made; the tally is read once, with its final figures.
    @Test func theReadIsAnnouncedAndItsTallyReadOnce() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await gate.waitUntilCalled(times: 3)

        #expect(read.finalTally == nil)
        #expect(read.spoken.isEmpty)
        gate.release()
        await waitUntil { read.phase == .finished }
        await read.signIn.waitUntilFinished()

        #expect(
            Set(read.spoken.prefix(3)) == [
                "Codex read: version 0.164.0, 2 skills, 1 plugin, 1 connection.",
                "Claude Code read: version 2.1.304, 4 skills, 2 plugins, 4 connections.",
                "Gemini CLI read: version 0.38.2, 1 skill, 0 plugins, 1 connection.",
            ])
        #expect(read.spoken.last == "Reading finished. Your library is created.")
        #expect(read.finalTally == "14 places read · 9 commands run · 0 changed in your apps")
    }

    /// The tally keeps its totals while the sign-in reads, which the commit
    /// never waits for, are still landing, on S05 and on S06, and VoiceOver
    /// hears it only once its figures are final.
    @Test func theTallyIsFinalOnlyOnceTheSignInLands() async throws {
        let signInGate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(signInGate: signInGate)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .finished }

        #expect(!read.isTallyFinal)
        #expect(read.tallyTotals?.places == 14)
        #expect(read.tallyTotals?.commands == 9)
        #expect(read.finalTally == nil)
        LaunchpadStageView.footer(for: flow).primary?.action()
        #expect(LaunchpadTileSequenceScreen.face(flow) == .found)
        #expect(LaunchpadTileSequenceScreen.foundFigures(flow, read: read)?.totals?.places == 14)

        signInGate.release()
        await read.signIn.waitUntilFinished()

        #expect(read.isTallyFinal)
        #expect(read.tallyTotals == nil)
        #expect(read.finalTally == "14 places read · 9 commands run · 0 changed in your apps")
        let figures = try #require(LaunchpadTileSequenceScreen.foundFigures(flow, read: read))
        #expect(figures.places == 14)
        #expect(figures.commands == 9)
        #expect(figures.totals == nil)
    }

    /// Stop is the footer's later slot while the read runs, so Tab reaches
    /// it and ⎋ presses it; once the library is made it is Set up later
    /// again.
    @Test func stopIsTheLaterSlotWhileReading() async throws {
        let gate = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(readGate: gate)
        defer { fixture.remove() }
        let flow = fixture.flow()
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await gate.waitUntilCalled(times: 3)

        guard case .stop = LaunchpadStageView.footer(for: flow).later else {
            Issue.record("the later slot is not Stop while reading")
            return
        }
        gate.release()
        await waitUntil { read.phase == .finished }
        guard case .setUpLater = LaunchpadStageView.footer(for: flow).later else {
            Issue.record("the later slot is not Set up later once read")
            return
        }
    }

    /// Each entry of the library is one sentence: name, kind, detail, whose
    /// it is, and which apps hold it.
    @Test func eachEntryIsOneSentence() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let state = try #require(workspace.library.state)
        let rows = LibraryRowPresence.rows(
            in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)

        #expect(
            rows.map(\.accessibilityLabel).prefix(4) == [
                "Frontend Design, skill, 2 copies · 2 versions, Unmanaged, in Codex, Claude Code and Gemini CLI",
                "Webapp Testing, skill, 2 copies · same content, Unmanaged, in Codex and Claude Code",
                "Release Notes, skill, Only in Claude Code, Unmanaged, in Claude Code",
                "GitHub, plugin, Includes 1 connection, Managed by its app, in Claude Code",
            ])
        #expect(rows.last?.accessibilityLabel == "Playwright, connection, Configured in 2 apps, Unmanaged, in Codex and Claude Code")
        #expect(LaunchpadCopy.Found.rowHint == "Space shows its copies and where they are.")
    }
}
