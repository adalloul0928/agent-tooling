import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Your apps, the read and what was found, in the gallery: S02 and its
/// states, V01, S04, the read under way (S05) with a notice, the read done,
/// S06, and the rerun variants, each in the stage's own window, in light and
/// dark.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad reads", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadReadsTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let source = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadTileSequenceScreen.swift"

    @Test func yourApps() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let flow = fixture.flow()
            flow.choosePath(.startHere)
            await LaunchpadDetection.of(flow).loadDeviceName()
            try snap(fixture, flow, "S02 Your apps", "three found, Kiro CLI not found", appearance)

            toggle(.kiro, in: flow)
            try snap(fixture, flow, "S02 Your apps", "Kiro CLI turned on while missing", appearance)
            toggle(.kiro, in: flow)
            toggle(.codex, in: flow)
            try snap(fixture, flow, "S02 Your apps", "Codex turned off", appearance)

        }
    }

    /// Popovers are windows of their own and do not draw in a stage capture,
    /// so their contents are drawn on their own.
    @Test func popovers() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                LaunchpadLookedPopover(client: .kiro, homeURL: fixture.home), area: "Launchpad",
                screen: "S02 Where Agent Tooling looked", state: "Kiro CLI not found",
                size: CGSize(width: Size.infoPopover, height: 190), appearance: appearance, source: Self.source)
            let workspace = try await fixture.sample(.afterRead).workspace
            let state = try #require(workspace.library.state)
            let rows = LibraryRowPresence.rows(
                in: state, observations: workspace.device.observations, managed: workspace.device.managedClients)
            let frontend = try #require(rows.first { $0.name == "Frontend Design" })
            let copies = await LibraryRowPresence.measured(frontend.copies)
            try gallerySnapshot(
                LaunchpadFoundRowPopover(row: frontend, copies: copies, home: fixture.home) {}, area: "Launchpad",
                screen: "S06 An entry's popover", state: "Frontend Design, two copies",
                size: CGSize(width: Size.infoPopover, height: 170), appearance: appearance,
                source: "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadFoundList.swift")
            let github = try #require(rows.first { $0.name == "GitHub" })
            try gallerySnapshot(
                LaunchpadFoundRowPopover(row: github, copies: [], home: fixture.home) {}, area: "Launchpad",
                screen: "S06 An entry's popover", state: "GitHub, a plugin",
                size: CGSize(width: Size.infoPopover, height: 110), appearance: appearance,
                source: "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadFoundList.swift")
        }
    }

    /// An empty Mac with Kiro CLI turned on while missing: it is read, found
    /// to hold nothing, and the library is empty.
    @Test func anEmptyLibrary() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture(.emptyMac)
            defer { fixture.remove() }
            let flow = fixture.flow()
            flow.choosePath(.startHere)
            toggle(.kiro, in: flow)
            try snap(fixture, flow, "V01 No apps found", "Kiro CLI turned on while missing", appearance)
            LaunchpadStageView.footer(for: flow).primary?.action()
            let read = LaunchpadTileSequenceScreen.read(flow)
            try snap(fixture, flow, "S04 What Agent Tooling reads", "Kiro CLI turned on while missing", appearance)
            LaunchpadStageView.footer(for: flow).primary?.action()
            await waitUntil { read.phase == .finished }
            LaunchpadStageView.footer(for: flow).primary?.action()
            try snap(fixture, flow, "S06 Here is what this Mac has", "an empty library", appearance)
        }
    }

    @Test func anEmptyMac() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture(.emptyMac)
            defer { fixture.remove() }
            let flow = fixture.flow()
            flow.choosePath(.startHere)
            try snap(fixture, flow, "V01 No apps found", "nothing found", appearance)

            // A record this build cannot read is in the way: the empty
            // library is not made over it.
            try Data("{".utf8).write(to: fixture.support.appending(path: "workspace.json"))
            LaunchpadStageView.footer(for: flow).primary?.action()
            await waitUntil { LaunchpadReadSession.of(flow).failure != nil }
            try snap(fixture, flow, "V01 No apps found", "the library could not be created", appearance)
        }
    }

    @Test func whatAgentToolingReads() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let flow = fixture.flow()
            flow.choosePath(.startHere)
            await LaunchpadDetection.of(flow).loadDeviceName()
            LaunchpadStageView.footer(for: flow).primary?.action()
            #expect(flow.step == .reads)
            try snap(fixture, flow, "S04 What Agent Tooling reads", "public build, projects on", appearance)
            flow.seedOverride?.findsProjectsFromClaudeHistory = false
            try snap(fixture, flow, "S04 What Agent Tooling reads", "public build, projects off", appearance)
            flow.seedOverride?.findsProjectsFromClaudeHistory = true
        }
    }

    @Test func theReadUnderWay() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            var environment = fixture.environment
            environment.firstRead = { client, manifest in GalleryPartialRead.reading(client, manifest: manifest) }
            let flow = LaunchpadFlow(entry: .firstRun, environment: environment)
            flow.choosePath(.startHere)
            let clock = GalleryClock()
            _ = flow.model(for: .reads) { LaunchpadReadSession(environment: environment, clock: { clock.now }) }
            LaunchpadStageView.footer(for: flow).primary?.action()
            LaunchpadStageView.footer(for: flow).primary?.action()
            let read = LaunchpadTileSequenceScreen.read(flow)
            await waitUntil { read.versionLines.count == 2 }
            clock.now = 2.4
            try snap(fixture, flow, "S05 Reading", "two versions in, Gemini CLI checking", appearance)
            clock.now = 12
            try snap(fixture, flow, "S05 Reading", "a read taking a while", appearance)
            await read.stop()
        }
    }

    @Test func theReadDone() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let flow = fixture.flow()
            flow.choosePath(.startHere)
            LaunchpadStageView.footer(for: flow).primary?.action()
            let read = LaunchpadTileSequenceScreen.read(flow)
            LaunchpadStageView.footer(for: flow).primary?.action()
            await waitUntil { read.phase == .finished }
            await read.signIn.waitUntilFinished()
            try snap(fixture, flow, "S05 Reading", "read, library created", appearance)

            LaunchpadStageView.footer(for: flow).primary?.action()
            #expect(flow.step == .found)
            try snap(fixture, flow, "S06 Here is what this Mac has", "Juniper", appearance)
        }
    }

    @Test func whileSignInIsChecked() async throws {
        for appearance in Self.both {
            let gate = GatedCommandRunner()
            let fixture = try await LaunchpadFixture(signInGate: gate)
            defer { fixture.remove() }
            let flow = fixture.flow()
            flow.choosePath(.startHere)
            LaunchpadStageView.footer(for: flow).primary?.action()
            let read = LaunchpadTileSequenceScreen.read(flow)
            LaunchpadStageView.footer(for: flow).primary?.action()
            await waitUntil { read.phase == .finished }
            LaunchpadStageView.footer(for: flow).primary?.action()
            try snap(fixture, flow, "S06 Here is what this Mac has", "checking sign-in", appearance)
            gate.release()
            await read.signIn.waitUntilFinished()
        }
    }

    /// A rerun using synthetic app observations.
    @Test func rerun() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let workspace = try await fixture.sample(.afterRead).workspace
            let flow = fixture.flow(.rerun, workspace: workspace)
            try snap(fixture, flow, "S02 Your apps", "rerun", appearance)
            LaunchpadStageView.footer(for: flow).primary?.action()
            let read = LaunchpadTileSequenceScreen.read(flow)
            try snap(fixture, flow, "S04 What Agent Tooling reads", "rerun", appearance)
            LaunchpadStageView.footer(for: flow).primary?.action()
            await waitUntil { read.phase == .finished }
            await read.signIn.waitUntilFinished()
            try snap(fixture, flow, "S05 Reading", "rerun, library up to date", appearance)
            LaunchpadStageView.footer(for: flow).primary?.action()
            try snap(fixture, flow, "S06 Here is what this Mac has", "rerun", appearance)
        }
    }

    /// A place read that no list held: its warning line under Claude Code's
    /// list, the well a line taller.
    @Test func aPlaceNotListedBefore() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            var environment = fixture.environment
            let stray = fixture.home.appending(path: ".claude/stray-settings.json")
            environment.firstRead = { client, manifest in
                let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
                let app = manifest.apps.first { $0.client == client }
                for place in app?.places ?? [] { continuation.yield(.placeRead(client, place.id)) }
                if client == .claude { continuation.yield(.unlisted(.claude, stray)) }
                return FirstRead.Reading(events) { continuation.finish() }
            }
            let flow = LaunchpadFlow(entry: .firstRun, environment: environment)
            flow.choosePath(.startHere)
            LaunchpadStageView.footer(for: flow).primary?.action()
            let read = LaunchpadTileSequenceScreen.read(flow)
            LaunchpadStageView.footer(for: flow).primary?.action()
            await waitUntil { read.unlisted[.claude] == [stray] }
            try snap(fixture, flow, "S05 Reading", "a place not listed before", appearance)
            await read.stop()
        }
    }

    /// A tile press, as Your apps makes it on a first run.
    private func toggle(_ client: ClientKind, in flow: LaunchpadFlow) {
        LaunchpadTileSequenceScreen.toggle(client, flow: flow)
    }

    private func snap(
        _ fixture: LaunchpadFixture, _ flow: LaunchpadFlow, _ screen: String, _ state: String, _ appearance: RenderAppearance
    ) throws {
        try galleryStageSnapshot(fixture.stage(flow), screen: screen, state: state, appearance: appearance, source: Self.source)
    }
}

/// A clock a gallery state sets by hand.
@MainActor
private final class GalleryClock {
    var now: TimeInterval = 0
}

/// A read caught part-way: Codex and Claude Code have answered `--version`
/// and read some places; Gemini CLI is still checking. Nothing finishes.
private enum GalleryPartialRead {
    static func reading(_ client: ClientKind, manifest: FirstReadManifest) -> FirstRead.Reading {
        let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        let app = manifest.apps.first { $0.client == client }
        let versions: [ClientKind: String] = [.codex: "codex-cli 0.164.0", .claude: "2.1.304 (Claude Code)"]
        let places = (app?.places ?? []).prefix(client == .codex ? 3 : (client == .claude ? 4 : 1))
        for place in places { continuation.yield(.placeRead(client, place.id)) }
        if let version = app?.commands.first, let line = versions[client] {
            continuation.yield(.commandStarted(client, version.id))
            continuation.yield(.commandFinished(client, version.id, .answered(status: 0, firstLine: line)))
            if let next = app?.commands.dropFirst().first { continuation.yield(.commandStarted(client, next.id)) }
        } else if let version = app?.commands.first {
            continuation.yield(.commandStarted(client, version.id))
        }
        return FirstRead.Reading(events) { continuation.finish() }
    }
}
