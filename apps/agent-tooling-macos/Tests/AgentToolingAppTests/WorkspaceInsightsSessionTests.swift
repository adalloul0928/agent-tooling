import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A scan reads and keeps aggregate findings, a stopped scan is never shown,
/// and asking for a skill queues a review rather than creating anything.
@MainActor
struct WorkspaceInsightsSessionTests {
    @Test func aScanIsShownAndKept() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let report = ShellRenderFixture.insightsReport()
        let services = StubInsightsServices(answer: report)
        let session = fixture.insightsSession(services)

        await session.scan(options: .init(clients: [.claude]))

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.report?.id == report.id)
        #expect(session.lastScannedAt == report.generatedAt)
        #expect(session.isScanning == false)
        // Kept, so the next launch shows the last scan rather than nothing.
        #expect(services.keptReport?.id == report.id)
        #expect(fixture.insightsSession(services).report?.id == report.id)
    }

    @Test func aScanThatCouldNotBeKeptStaysOnScreenAndSaysSo() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = StubInsightsServices(answer: ShellRenderFixture.insightsReport(), keepFails: true)
        let session = fixture.insightsSession(services)

        await session.scan(options: .init(clients: [.claude]))

        #expect(session.report != nil)
        #expect(session.errorMessage?.contains("could not be saved") == true)
    }

    @Test func stoppingAScanNeverReplacesWhatIsOnScreen() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport(), holdFor: .seconds(30))
        let session = fixture.insightsSession(services)

        let scanning = Task { await session.scan(options: .init(clients: [.claude])) }
        while !session.isScanning { await Task.yield() }
        session.cancelScan()
        await scanning.value

        #expect(session.isScanning == false)
        #expect(session.report == nil, "a stopped scan was saved over the screen")
        #expect(services.keptReport == nil)
    }

    @Test func clearingForgetsTheSavedReport() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let report = ShellRenderFixture.insightsReport()
        let services = StubInsightsServices(answer: report, restored: report)
        let session = fixture.insightsSession(services)
        #expect(session.report != nil)

        session.clear()

        #expect(session.report == nil)
        #expect(session.lastScannedAt == nil)
        #expect(services.keptReport == nil)
    }

    @Test func askingForASkillQueuesOneReviewAndItsDraft() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = fixture.insightsSession(StubInsightsServices(answer: ShellRenderFixture.insightsReport()))
        let recommendation = try #require(
            ShellRenderFixture.defaultRecommendations.first { $0.kind == .createCustomSkill })

        await session.requestSkillDraft(from: recommendation, targets: [.codex])

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.queuedDraftIDs.contains(recommendation.id))
        let queued = try PendingRequestQueueService.pendingRequests(store: fixture.store)
        #expect(queued.count == 1)
        let request = try #require(queued.first)
        #expect(request.kind == .createSkill)
        #expect(request.reviewDetails.instruction == recommendation.draftInstruction)
        // A review row with no payload behind it can never be opened.
        let draft = try fixture.store.requestDraft(request.id, as: CodexSkillDraftRequest.self)
        #expect(draft?.instruction == recommendation.draftInstruction)
        // Nothing was created: asking is the whole of what this action does.
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 6)

        // Asking twice does not queue the same thing twice.
        await session.requestSkillDraft(from: recommendation, targets: [.codex])
        #expect(try PendingRequestQueueService.pendingRequests(store: fixture.store).count == 1)
    }

    @Test func onlyADraftRecommendationCanBeAskedFor() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = fixture.insightsSession(StubInsightsServices(answer: ShellRenderFixture.insightsReport()))
        let recommendation = try #require(
            ShellRenderFixture.defaultRecommendations.first { $0.kind == .useExistingSkill })

        await session.requestSkillDraft(from: recommendation, targets: [.codex])

        #expect(session.queuedDraftIDs.isEmpty)
        #expect(try PendingRequestQueueService.pendingRequests(store: fixture.store).isEmpty)
    }
}

extension ShellRenderFixture {
    func insightsSession(_ services: any InsightsServicing) -> WorkspaceInsightsSession {
        WorkspaceInsightsSession(
            library: workspace.library, store: store, homeRoot: home, services: services)
    }
}
