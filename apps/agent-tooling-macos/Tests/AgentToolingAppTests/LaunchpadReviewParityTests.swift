import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Verifies the placement grid and helper selections produce exactly the reviewed
/// install steps. Left-alone and already-installed entries stay visible but do
/// not execute. Uses actual screen models with scripted client commands.
@Suite("Launchpad review parity", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadReviewParityTests {
    /// The fragments' walk: S10's two Will install cells and S11's two ticked
    /// rows are S12's four steps, and every count on the way says four.
    @Test func theFragmentsWalkInstallsWhatS10AndS11Decided() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.remove() }

        // S11 as the fragment draws it: Gemini CLI unticked.
        let walked = try await Self.walk(fixture, onS10: { _ in }, onS11: { $0.toggle(.gemini) })

        try Self.expectParity(walked)
        #expect(walked.willInstall.count == 2)
        #expect(walked.leftAlone.count == 1)
        #expect(walked.ticked == [.codex, .claude])
        #expect(walked.review.runnableCount == 4)
        #expect(walked.review.title == "Install 4 changes")
        #expect(walked.s10Note == "2 changes so far")
        #expect(walked.s11Title == "Review 4 changes…")
    }

    /// Any other choice holds the same way: Supabase turned to Add on S10,
    /// and on S11 Claude Code unticked while Gemini CLI stays ticked.
    @Test func anotherChoiceInstallsWhatWasChosen() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.remove() }

        let walked = try await Self.walk(
            fixture,
            onS10: { placement in
                let supabase = try #require(placement.items.first { $0.name == "Supabase" })
                placement.toggle(.init(item: supabase.artifactID, app: .claude))
            },
            onS11: { $0.toggle(.claude) })

        try Self.expectParity(walked)
        #expect(walked.willInstall.count == 1)
        #expect(walked.ticked == [.codex, .gemini])
        #expect(walked.review.runnableCount == 3)
        #expect(walked.review.title == "Install 3 changes")
        #expect(walked.s10Note == "1 change so far")
        #expect(walked.s11Title == "Review 3 changes…")
    }

    // MARK: - The walk

    /// One item and one app: a cell of the placement grid, or a step.
    private struct Pair: Hashable, CustomStringConvertible {
        let artifactID: ArtifactID
        let client: ClientKind
        var description: String { "\(artifactID.rawValue.uuidString.prefix(8)) × \(client.rawValue)" }
    }

    /// What S10 and S11 showed and decided, and the review they opened.
    private struct Walked {
        let willInstall: Set<Pair>
        let hasIt: Set<Pair>
        let leftAlone: Set<Pair>
        let ticked: [ClientKind]
        let helper: ArtifactID
        let s10Note: String?
        let s11Title: String
        let review: ScopedPlanReview
    }

    /// Juniper with this copy of Agent Tooling in the fixture's own
    /// Applications folder, so its helper can be handed to apps.
    private static func fixture() async throws -> LaunchpadFixture {
        var fixture = try await LaunchpadFixture()
        let applications = fixture.world.home.root.appending(path: "Applications", directoryHint: .isDirectory)
        fixture.environment.installation = { HelperBundle.inApplications(applications) }
        return fixture
    }

    /// From Start your library on: S10 read as the screen reads it, changed by
    /// `onS10`, saved by Continue; S11 read, changed by `onS11`, recorded by
    /// its primary; then the review it opens, read.
    private static func walk(
        _ fixture: LaunchpadFixture, onS10: (LaunchpadPlacement) throws -> Void, onS11: (AgentToolingHookUp) -> Void
    ) async throws -> Walked {
        let (flow, _) = try await fixture.flow(at: .afterLibrary)

        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: LaunchpadPlaceScreen.decisions(for: flow))
        try onS10(placement)
        func cells(where matches: (LaunchpadPlacement.Cell) -> Bool) -> Set<Pair> {
            Set(placement.cells.filter { matches($0.value) }.map { Pair(artifactID: $0.key.item, client: $0.key.app) })
        }
        let willInstall = cells { $0 == .willInstall }
        let hasIt = cells { $0 == .hasIt }
        let leftAlone = cells { if case .leftAlone = $0 { true } else { false } }
        let s10Note = LaunchpadStageView.footer(for: flow).note
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { flow.step == .ask }

        let hookUp = AgentToolingHookUp.of(flow)
        await hookUp.load(decisions: flow.decisions)
        onS11(hookUp)
        let ticked = hookUp.rows.filter(\.addsStep).map(\.client)
        let s11Title = hookUp.primaryTitle
        try #require(LaunchpadAskScreen.footer(flow).primary).action()
        await waitUntil { flow.presentedReview != nil }

        let review = try #require(flow.presentedReview)
        await review.prepare()
        return Walked(
            willInstall: willInstall, hasIt: hasIt, leftAlone: leftAlone, ticked: ticked,
            helper: try #require(flow.decisions.helperArtifactID), s10Note: s10Note, s11Title: s11Title, review: review)
    }

    /// The review runs exactly S10's Will install cells and the connection for
    /// each of S11's ticked apps; S10's Left alone cells are drawn in place,
    /// not run; Has it never shows.
    private static func expectParity(_ walked: Walked, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let review = walked.review
        #expect(review.phase == .ready, sourceLocation: sourceLocation)
        let steps = review.groups.flatMap { group in
            group.steps.map { (pair: Pair(artifactID: $0.id.artifactID, client: group.client), step: $0) }
        }
        let runs = Set(steps.filter(\.step.isChange).map(\.pair))
        let connections = Set(walked.ticked.map { Pair(artifactID: walked.helper, client: $0) })

        #expect(runs == walked.willInstall.union(connections), sourceLocation: sourceLocation)
        #expect(Set(steps.filter { $0.step.state == .leftAlone }.map(\.pair)) == walked.leftAlone, sourceLocation: sourceLocation)
        #expect(!walked.hasIt.isEmpty, "the sample world has Has it cells to hold the review to", sourceLocation: sourceLocation)
        #expect(Set(steps.map(\.pair)).isDisjoint(with: walked.hasIt), "Has it is never a step", sourceLocation: sourceLocation)
        #expect(
            !steps.contains { if case .willNotRun = $0.step.state { true } else { false } },
            "every decided step has a command to run", sourceLocation: sourceLocation)
        #expect(review.runnableCount == runs.count, sourceLocation: sourceLocation)
        #expect(review.listedCount == runs.count + walked.leftAlone.count, sourceLocation: sourceLocation)
    }
}
