import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// The daily insights run as this Mac allows it: the deep dive only when
/// allowed, and waited for; a local-only scan on a day it is allowed alone;
/// today's runs, exactly, for a workspace made before the choice existed;
/// summaries only from the apps asked for; and turning the runs off stops
/// only the run the launch started.
@Suite("Insights consent", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceInsightsSessionConsentTests {
    private static let managed: [ClientKind] = [.codex, .claude, .gemini]
    private static let diveOnly = AssistantRunConsent(weeklyReview: false, dailyDeepDive: true, localInsights: false)
    private static let localOnly = AssistantRunConsent(weeklyReview: false, dailyDeepDive: false, localInsights: true)

    @Test func withEveryRunOffNothingIsRead() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = AssistantRunInsightsServices(digests: [AssistantRunInsightsServices.digest(.claude)])
        let session = fixture.insightsSession(services)

        await session.runScheduledInsightsIfDue(consent: .off, managedClients: Self.managed)

        #expect(services.scannedClients.isEmpty)
        #expect(services.deepDives.isEmpty)
        #expect(session.report == nil)
    }

    /// The run returns only once the assistant has answered, so the weekly
    /// review that follows it never holds the assistant at the same time.
    @Test func theDeepDiveIsWaitedFor() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsDeepDives: true)
        let session = fixture.insightsSession(services)

        let run = Task {
            await session.runScheduledInsightsIfDue(consent: Self.diveOnly, managedClients: Self.managed)
            return (diving: session.isDeepDiving, landed: session.report?.deepDive != nil)
        }
        await services.waitUntilHeld()
        #expect(session.isDeepDiving)
        services.releaseHeld()
        let onReturn = await run.value

        #expect(!onReturn.diving, "the run returned after the dive, not beside it")
        #expect(onReturn.landed)
        #expect(services.deepDives == [.claude], "Claude Code is the assistant when it is managed")
        #expect(services.scannedClients == [[.codex, .claude, .gemini]], "the managed apps, and only them")
    }

    /// A day with only local insights allowed runs the keyword pass alone:
    /// no assistant, nothing leaves this Mac. A fresh report is not redone.
    @Test func aLocalOnlyDayScansWithoutTheAssistant() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = AssistantRunInsightsServices(digests: [AssistantRunInsightsServices.digest(.claude)])
        let session = fixture.insightsSession(services)

        await session.runScheduledInsightsIfDue(consent: Self.localOnly, managedClients: Self.managed)

        #expect(services.scannedClients.count == 1)
        #expect(services.deepDives.isEmpty)
        #expect(session.report != nil)

        await session.runScheduledInsightsIfDue(consent: Self.localOnly, managedClients: Self.managed)
        #expect(services.scannedClients.count == 1, "a report from today is not redone")

        let stale = AssistantRunInsightsServices(
            restored: ShellRenderFixture.insightsReport(generatedAt: .now.addingTimeInterval(-25 * 3_600)))
        let staleSession = fixture.insightsSession(stale)
        #expect(staleSession.isReportStale)
        await staleSession.runScheduledInsightsIfDue(consent: Self.localOnly, managedClients: [.kiro])
        #expect(stale.scannedClients == [[.kiro]], "a Kiro CLI Mac has history to scan, and no assistant")
        #expect(stale.deepDives.isEmpty)
    }

    /// A workspace made before the choice existed runs the deep dive when it
    /// is due and never a local scan on its own: what it always did.
    @Test func todaysRunsAreUnchangedForAnOlderWorkspace() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var fresh = ShellRenderFixture.insightsReport(generatedAt: .now.addingTimeInterval(-25 * 3_600))
        fresh.deepDive = ShellRenderFixture.insightsDeepDive(at: .now.addingTimeInterval(-3_600))
        let services = AssistantRunInsightsServices(digests: [AssistantRunInsightsServices.digest(.codex)], restored: fresh)
        let session = fixture.insightsSession(services)

        await session.runScheduledInsightsIfDue(consent: .existingBehaviour, managedClients: Self.managed)
        #expect(services.scannedClients.isEmpty, "the dive is fresh, and no local scan runs on its own")

        let kiroOnly = AssistantRunInsightsServices()
        await fixture.insightsSession(kiroOnly).runScheduledInsightsIfDue(consent: .existingBehaviour, managedClients: [.kiro])
        #expect(kiroOnly.scannedClients.isEmpty, "a Kiro CLI Mac gains no daily scan")
    }

    @Test func summariesForAReviewComeOnlyFromTheAppsAskedFor() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = AssistantRunInsightsServices(
            digests: [.codex, .claude, .kiro].map(AssistantRunInsightsServices.digest))
        let session = fixture.insightsSession(services)

        let digests = await session.digestsForReview(clients: [.codex, .claude])
        #expect(Set(digests.map(\.client)) == [.codex, .claude])
        #expect(services.scannedClients == [[.codex, .claude]])

        let none = await session.digestsForReview(clients: [.gemini])
        #expect(none.isEmpty, "Gemini CLI keeps no history this app reads")
        #expect(services.scannedClients.count == 1, "and nothing was read for it")
    }

    /// Turning the runs off stops the run the launch started, and never a
    /// scan a person started on Insights.
    @Test func turningTheRunsOffStopsOnlyTheScheduledRun() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsDeepDives: true)
        let session = fixture.insightsSession(services)
        let scheduled = Task { await session.runScheduledInsightsIfDue(consent: Self.diveOnly, managedClients: Self.managed) }
        await services.waitUntilHeld()

        session.cancelScheduledRun()

        #expect(!session.isDeepDiving)
        await scheduled.value
        #expect(session.report?.deepDive == nil, "the stopped dive kept nothing")

        let manualServices = AssistantRunInsightsServices(holdsScans: true)
        let manual = fixture.insightsSession(manualServices)
        let scan = Task { await manual.scan(options: InsightScanOptions(clients: [.claude])) }
        await manualServices.waitUntilHeld()
        manual.cancelScheduledRun()
        #expect(manual.isScanning, "a scan somebody started is left alone")
        manualServices.releaseHeld()
        await scan.value
        #expect(manual.report != nil)
    }

    /// Each switch stops only the scheduled run it allows: the deep dive's
    /// switch a deep dive, local insights' a keyword scan run on its own.
    @Test func eachSwitchStopsOnlyTheScheduledRunItAllows() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let diving = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsDeepDives: true)
        let dive = fixture.insightsSession(diving)
        let diveRun = Task { await dive.runScheduledInsightsIfDue(consent: Self.diveOnly, managedClients: Self.managed) }
        await diving.waitUntilHeld()
        dive.cancelScheduledRun(unlessAllowedBy: Self.diveOnly)
        #expect(dive.isDeepDiving, "local insights turned off leaves the deep dive running")
        dive.cancelScheduledRun(unlessAllowedBy: Self.localOnly)
        #expect(!dive.isDeepDiving, "the deep dive turned off stops it")
        await diveRun.value
        #expect(dive.report?.deepDive == nil)

        let scanning = AssistantRunInsightsServices(holdsScans: true)
        let local = fixture.insightsSession(scanning)
        let localRun = Task { await local.runScheduledInsightsIfDue(consent: Self.localOnly, managedClients: Self.managed) }
        await scanning.waitUntilHeld()
        local.cancelScheduledRun(unlessAllowedBy: Self.localOnly)
        #expect(local.isScanning, "the deep dive turned off leaves a keyword scan on its own running")
        local.cancelScheduledRun(unlessAllowedBy: Self.diveOnly)
        #expect(!local.isScanning, "local insights turned off stops it")
        scanning.releaseHeld()
        await localRun.value
        #expect(local.report == nil, "the stopped scan kept nothing")
    }

    /// Asked again while the launch's run is under way (a main window opened
    /// again), the daily run waits for it, deep dive and all, and runs
    /// nothing of its own.
    @Test func aSecondCallWaitsForTheRunUnderWay() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = AssistantRunInsightsServices(
            digests: [AssistantRunInsightsServices.digest(.claude)], holdsDeepDives: true)
        let session = fixture.insightsSession(services)
        let order = InsightsCallOrder()

        let first = Task { await session.runScheduledInsightsIfDue(consent: Self.diveOnly, managedClients: Self.managed) }
        await services.waitUntilHeld()
        let second = Task {
            await session.runScheduledInsightsIfDue(consent: Self.diveOnly, managedClients: Self.managed)
            order.events.append("second returned")
        }
        for _ in 0..<20 { await Task.yield() }
        order.events.append("released")
        services.releaseHeld()
        await first.value
        await second.value

        #expect(order.events == ["released", "second returned"], "the second call waited for the deep dive")
        #expect(services.deepDives == [.claude], "one deep dive, not two")
        #expect(services.scannedClients.count == 1)
    }
}

/// What happened, in the order it did.
@MainActor
private final class InsightsCallOrder {
    var events: [String] = []
}
