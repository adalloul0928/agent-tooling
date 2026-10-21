import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The weekly review as the launch runs it: only when this Mac allows it and
/// it is due, never dropped by an audit that lands meanwhile, tried again a
/// day after one that failed, stopped when the runs are turned off, and handed
/// summaries only from the apps this Mac manages.
@Suite("Checkup schedule", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceSetupSessionScheduleTests {
    private static let weeklyOnly = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)
    private static let home = URL(filePath: "/Users/example")

    // MARK: Two generations

    /// An audit that lands while a review runs (an apply ends with one) keeps
    /// the review: its answer joins the checkup, and the review's own flag
    /// clears when it ends.
    @Test func anAuditDuringAReviewKeepsTheReview() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: Self.home, review: false)
        let services = AssistantRunSetupServices(restored: restored, holdsReviews: true)
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let session = fixture.workspace.setup

        let review = Task { await session.review(purpose: .checkup) }
        await services.waitUntilAReviewIsHeld()
        await session.audit(scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false)
        #expect(session.isReviewing, "the audit did not drop the review")
        #expect(!session.isAuditing)

        services.releaseReviews()
        await review.value
        #expect(!session.isReviewing)
        #expect(session.checkup?.review != nil, "the review's answer joined the checkup")
        #expect(services.reviewCalls == 1)
    }

    /// A review that lands after a newer audit joins it without what it
    /// said about findings that audit no longer has: a fix for one of those
    /// would be a button with nothing left to fix. What names no finding
    /// stands.
    @Test func aReviewLandingAfterANewerAuditLeavesOutFindingsItNoLongerHas() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: Self.home, review: false)
        let gone = try #require(restored.audit.findings.first)
        let services = AssistantRunSetupServices(restored: restored, holdsReviews: true)
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let session = fixture.workspace.setup

        let review = Task { await session.review(purpose: .checkup) }
        await services.waitUntilAReviewIsHeld()
        await session.audit(scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false)
        #expect(session.checkup?.audit.findings.contains { $0.id == gone.id } == false, "the newer audit no longer has it")
        services.releaseReviews()
        await review.value

        let recommendations = try #require(session.checkup?.review?.recommendations)
        #expect(!recommendations.contains { $0.findingIDs.contains(gone.id) }, "no fix for a finding that is gone")
        #expect(recommendations.map(\.id) == ["review:claudecode:1:setting"], "what the assistant read for itself stands")
    }

    @Test func aRecommendationStandsWhileTheAuditHasAFindingItNames() {
        let kept = SetupFinding(
            kind: .brokenSkillLink, severity: .medium, client: .claude, subject: "kept", title: "kept points at nothing",
            detail: "", evidence: [], actions: [])
        let gone = SetupFinding(
            kind: .brokenSkillLink, severity: .medium, client: .claude, subject: "gone", title: "gone points at nothing",
            detail: "", evidence: [], actions: [])
        let audit = SetupAuditReport(clients: [.claude], findings: [kept], counts: [:])
        func recommendation(
            _ id: String, _ provenance: SetupRecommendationProvenance, _ findings: [SetupFinding]
        ) -> SetupRecommendation {
            SetupRecommendation(
                id: id, category: .cleanup, title: id, summary: "", rationale: "", client: .claude, priority: 1,
                provenance: provenance, action: .readOnly, findingIDs: findings.map(\.id))
        }
        let all = [
            recommendation("kept", .audit(findingID: kept.id), [kept]),
            recommendation("gone", .audit(findingID: gone.id), [gone]),
            recommendation("gone-by-provenance", .audit(findingID: gone.id), []),
            recommendation("one-of-two", .opinion, [kept, gone]),
            recommendation("read", .investigated(source: "~/.claude/settings.json"), []),
            recommendation("view", .opinion, []),
        ]
        #expect(
            WorkspaceSetupSession.recommendations(all, over: audit).map(\.id) == ["kept", "one-of-two", "read", "view"])
    }

    // MARK: When the review is due

    /// The stage audits twice before Home opens (after the read and when
    /// Done appears). Neither is a review, so the first review is still due
    /// when Home opens, and runs then if this Mac allows it.
    @Test func theStagesAuditsLeaveTheFirstReviewForHome() async throws {
        let services = AssistantRunSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services, assistantRuns: Self.weeklyOnly)
        defer { fixture.remove() }
        let session = fixture.workspace.setup
        for _ in 0..<2 { await session.audit(scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false) }
        #expect(session.checkup != nil)
        #expect(session.isReviewDue(consent: Self.weeklyOnly))
        #expect(!session.isReviewDue(consent: .off), "a review this Mac does not allow is never due")

        await session.runScheduledReviewIfDue(consent: Self.weeklyOnly)

        #expect(services.reviewCalls == 1)
        #expect(session.checkup?.review != nil)
        #expect(!session.isReviewDue(consent: Self.weeklyOnly), "the next one is a week away")
    }

    @Test func aReviewIsDueOnlyWhenTheLastIsAWeekOldAndAnAssistantCanRunIt() async throws {
        var checkup = ShellRenderFixture.setupCheckup(home: Self.home)
        checkup.review?.generatedAt = .now.addingTimeInterval(-6 * 24 * 3_600)
        let fixture = try await ShellRenderFixture(setupServices: AssistantRunSetupServices(restored: checkup))
        defer { fixture.remove() }
        let session = fixture.workspace.setup
        #expect(!session.isReviewDue(consent: .existingBehaviour), "six days old")
        #expect(session.isReviewDue(consent: .existingBehaviour, now: .now.addingTimeInterval(2 * 24 * 3_600)))

        // With neither Claude Code nor Codex managed, no review is ever due.
        await fixture.workspace.device.setEnabled(.claude, false)
        await fixture.workspace.device.setEnabled(.codex, false)
        #expect(!session.isReviewDue(consent: .existingBehaviour, now: .now.addingTimeInterval(30 * 24 * 3_600)))

        let empty = try await ShellRenderFixture(setupServices: AssistantRunSetupServices())
        defer { empty.remove() }
        #expect(!empty.workspace.setup.isReviewDue(consent: .existingBehaviour), "there is no audit to read yet")
    }

    /// A review that fails is tried again a day later, not a week: the
    /// attempt is kept as it starts, and kept across launches.
    @Test func aFailedReviewIsTriedAgainAfterADay() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: Self.home, review: false)
        let services = AssistantRunSetupServices(
            restored: restored, answer: .failure(SetupReviewError.clientFailed(.claude, 1, "401 Unauthorized")))
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let session = fixture.workspace.setup
        let before = Date.now

        await session.runScheduledReviewIfDue(consent: .existingBehaviour)

        #expect(services.reviewCalls == 1)
        #expect(session.reviewMessage?.contains("401 Unauthorized") == true)
        let attempted = try #require(session.checkup?.reviewAttemptedAt)
        #expect(attempted >= before)
        #expect(services.kept?.reviewAttemptedAt == attempted, "the attempt is kept for the next launch")

        await session.runScheduledReviewIfDue(consent: .existingBehaviour)
        #expect(services.reviewCalls == 1, "not again the same day")
        #expect(!session.isReviewDue(consent: .existingBehaviour, now: attempted.addingTimeInterval(23 * 3_600)))
        #expect(session.isReviewDue(consent: .existingBehaviour, now: attempted.addingTimeInterval(25 * 3_600)))
    }

    @Test func aCheckupKeptBeforeTheRetryExistedStillReads() throws {
        let checkup = ShellRenderFixture.setupCheckup(home: Self.home)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(checkup)) as? [String: Any])
        object["reviewAttemptedAt"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SetupCheckup.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.reviewAttemptedAt == nil)
        #expect(decoded.audit.findings.map(\.id) == checkup.audit.findings.map(\.id))
    }

    // MARK: The audit on open

    /// With Check my apps each time Agent Tooling opens off, the audit on
    /// open never checks the apps itself: with nothing checked it keeps the
    /// checkup it had; with a check recorded it audits that.
    @Test func theAuditOnOpenScansOnlyWhenAllowed() async throws {
        let observer = CountingDeviceObserver([
            ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.304")
        ])
        let fixture = try await ShellRenderFixture(deviceObserver: observer, setupServices: AssistantRunSetupServices())
        defer { fixture.remove() }
        let session = fixture.workspace.setup

        await session.runScheduledAudit(allowsScan: false)
        #expect(observer.fullChecks == 0)
        #expect(session.checkup == nil, "nothing was audited over an empty check")

        await fixture.workspace.device.adopt([
            ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.304")
        ])
        await session.runScheduledAudit(allowsScan: false)
        #expect(observer.fullChecks == 0)
        #expect(session.checkup != nil, "the recorded check was audited")

        let scanning = try await ShellRenderFixture(deviceObserver: observer, setupServices: AssistantRunSetupServices())
        defer { scanning.remove() }
        await scanning.workspace.setup.runScheduledAudit(allowsScan: true)
        #expect(observer.fullChecks == 1, "allowed, it checks first when nothing was checked")
    }

    @Test func anAuditWithoutTheLoginShellNeverAsksForTheSearchPath() async throws {
        let services = AssistantRunSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        await fixture.workspace.setup.audit(asksLoginShell: false)
        #expect(services.searchPathCalls == 0)
        await fixture.workspace.setup.audit()
        #expect(services.searchPathCalls == 1)
    }

    // MARK: Summaries

    /// The review's summaries come from the apps this Mac manages, and from
    /// nowhere while the weekly review is off, even when asked for by hand.
    @Test func summariesComeOnlyFromManagedAppsAndOnlyWhileTheWeeklyReviewIsAllowed() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: Self.home, review: false)
        let insights = AssistantRunInsightsServices(digests: [.codex, .claude, .kiro].map(AssistantRunInsightsServices.digest))
        let services = AssistantRunSetupServices(restored: restored)
        let fixture = try await ShellRenderFixture(
            insightsServices: insights, setupServices: services, assistantRuns: Self.weeklyOnly)
        defer { fixture.remove() }
        await fixture.workspace.device.setEnabled(.gemini, false)
        await fixture.workspace.device.setEnabled(.kiro, false)

        await fixture.workspace.setup.review(purpose: .checkup)

        #expect(insights.scannedClients == [[.codex, .claude]], "only the managed apps are read")
        #expect(services.reviewDigests == [2], "Codex's summary and Claude Code's, never Kiro CLI's")

        let off = AssistantRunInsightsServices(digests: [AssistantRunInsightsServices.digest(.claude)])
        let offServices = AssistantRunSetupServices(restored: restored)
        let refused = try await ShellRenderFixture(insightsServices: off, setupServices: offServices, assistantRuns: .off)
        defer { refused.remove() }
        await refused.workspace.setup.review(purpose: .checkup)
        #expect(offServices.reviewCalls == 1, "a review by hand still runs")
        #expect(offServices.reviewDigests == [0], "but sends no summary")
        #expect(off.scannedClients.isEmpty, "and reads no history")
    }

    /// The weekly review turned off while a review's summaries are being
    /// read: none of them go, though the review asked for by hand still runs.
    @Test func theWeeklyReviewTurnedOffWhileItsSummariesAreReadSendsNone() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: Self.home, review: false)
        let insights = AssistantRunInsightsServices(digests: [AssistantRunInsightsServices.digest(.claude)], holdsScans: true)
        let services = AssistantRunSetupServices(restored: restored)
        let fixture = try await ShellRenderFixture(
            insightsServices: insights, setupServices: services, assistantRuns: Self.weeklyOnly)
        defer { fixture.remove() }

        let review = Task { await fixture.workspace.setup.review(purpose: .checkup) }
        await insights.waitUntilHeld()
        await fixture.workspace.recordAssistantRun(.weeklyReview, false).value
        insights.releaseHeld()
        await review.value

        #expect(services.reviewCalls == 1, "the review asked for by hand still runs")
        #expect(services.reviewDigests == [0], "and sends no summary")
    }

    // MARK: Turning it off

    @Test func turningTheReviewOffStopsTheScheduledOne() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: Self.home, review: false)
        let services = AssistantRunSetupServices(restored: restored, holdsReviews: true)
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let session = fixture.workspace.setup

        let scheduled = Task { await session.runScheduledReviewIfDue(consent: .existingBehaviour) }
        await services.waitUntilAReviewIsHeld()
        session.cancelScheduledReview()
        #expect(!session.isReviewing)

        await scheduled.value
        #expect(services.cancelledReviews == 1, "the review's command was stopped")
        #expect(session.checkup?.review == nil, "nothing it said was kept")
        #expect(session.reviewMessage == nil, "a stopped review is not a failed one")
    }

    @Test func aReviewAskedForByHandIsNotStoppedWithTheScheduledRuns() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: Self.home, review: false)
        let services = AssistantRunSetupServices(restored: restored, holdsReviews: true)
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let session = fixture.workspace.setup

        let manual = Task { await session.review(purpose: .checkup) }
        await services.waitUntilAReviewIsHeld()
        session.cancelScheduledReview()
        #expect(session.isReviewing)

        services.releaseReviews()
        await manual.value
        #expect(session.checkup?.review != nil)
        #expect(services.cancelledReviews == 0)
    }
}

// MARK: - Scripted services

/// A setup service that answers from memory and remembers what it was handed:
/// how many reviews ran and how many summaries each was given, how often the
/// login shell was asked, and which reviews were stopped. `holdsReviews` keeps
/// every review waiting until `releaseReviews()`, or until it is cancelled.
/// With `alongside`, it counts the reviews that started while that insights
/// service held a deep dive or a scan.
final class AssistantRunSetupServices: SetupServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var checkup: SetupCheckup?
    private let answer: Result<SetupReview, any Error>?
    private let holdsReviews: Bool
    private let alongside: AssistantRunInsightsServices?
    private var released = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var digestCounts: [Int] = []
    private var searchPaths = 0
    private var cancelled = 0
    private var beside = 0

    /// `answer` is the assistant's; nil answers with a review over the audit.
    init(
        restored: SetupCheckup? = nil, answer: Result<SetupReview, any Error>? = nil, holdsReviews: Bool = false,
        alongside: AssistantRunInsightsServices? = nil
    ) {
        checkup = restored
        self.answer = answer
        self.holdsReviews = holdsReviews
        self.alongside = alongside
    }

    var reviewCalls: Int { lock.withLock { digestCounts.count } }
    /// How many reviews started while `alongside` held a run.
    var reviewsBesideADive: Int { lock.withLock { beside } }
    /// How many summaries each review was handed, in order.
    var reviewDigests: [Int] { lock.withLock { digestCounts } }
    var searchPathCalls: Int { lock.withLock { searchPaths } }
    var cancelledReviews: Int { lock.withLock { cancelled } }
    var kept: SetupCheckup? { lock.withLock { checkup } }

    /// Returns once a review is waiting to be released, so a test acts while
    /// the assistant is reading and not before it was asked.
    func waitUntilAReviewIsHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if !held.isEmpty { return true }
                heldWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lets every held review answer.
    func releaseReviews() {
        let waiting = lock.withLock {
            released = true
            let waiting = held
            held = [:]
            return waiting
        }
        for continuation in waiting.values { continuation.resume() }
    }

    func searchPath(homeURL: URL) async -> [URL] {
        lock.withLock { searchPaths += 1 }
        return []
    }

    func review(
        client: ClientKind, purpose: SetupReviewPrompt.Purpose, audit: SetupAuditReport, digests: [ConversationDigest],
        focus: ClientKind?, clientVersions: [ClientKind: String], releaseNotes: [String]
    ) async throws -> SetupReview {
        let isBeside = alongside?.isHolding == true
        lock.withLock {
            digestCounts.append(digests.count)
            if isBeside { beside += 1 }
        }
        if holdsReviews { try await hold() }
        if let answer { return try answer.get() }
        return await ShellRenderFixture.setupReview(over: audit)
    }

    private func hold() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (resumeNow, waiters) = lock.withLock {
                    if released || Task.isCancelled { return (true, [CheckedContinuation<Void, Never>]()) }
                    held[id] = continuation
                    let waiters = heldWaiters
                    heldWaiters = []
                    return (false, waiters)
                }
                for waiter in waiters { waiter.resume() }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = lock.withLock { held.removeValue(forKey: id) }
            continuation?.resume()
        }
        if Task.isCancelled {
            lock.withLock { cancelled += 1 }
            throw CancellationError()
        }
    }

    func lastCheckup() -> SetupCheckup? { lock.withLock { checkup } }
    func keep(_ checkup: SetupCheckup) throws { lock.withLock { self.checkup = checkup } }
    func releaseNotes(for client: ClientKind, installedVersion: String?) async throws -> [ClientReleaseNote] { [] }
    func lastClientReviews() -> [ClientKind: ClientReview] { [:] }
    func keep(clientReviews: [ClientKind: ClientReview]) throws {}
}

/// An insights service that answers from memory and remembers which apps
/// each scan was asked to read and which assistant each deep dive ran in.
/// `holdsDeepDives` keeps every deep dive waiting until `releaseDeepDives()`,
/// or until it is cancelled.
final class AssistantRunInsightsServices: InsightsServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let digests: [ConversationDigest]
    private let holdsDeepDives: Bool
    private let holdsScans: Bool
    private var kept: InsightsReport?
    private var released = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var scans: [Set<ClientKind>] = []
    private var dives: [ClientKind] = []

    init(
        digests: [ConversationDigest] = [], restored: InsightsReport? = nil, holdsDeepDives: Bool = false,
        holdsScans: Bool = false
    ) {
        self.digests = digests
        kept = restored
        self.holdsDeepDives = holdsDeepDives
        self.holdsScans = holdsScans
    }

    /// The apps each scan read, in order.
    var scannedClients: [Set<ClientKind>] { lock.withLock { scans } }
    /// Whether a scan or a deep dive is waiting to be released now.
    var isHolding: Bool { lock.withLock { !held.isEmpty } }
    /// The assistant each deep dive ran in, in order.
    var deepDives: [ClientKind] { lock.withLock { dives } }

    static func digest(_ client: ClientKind) -> ConversationDigest {
        ConversationDigest(
            conversationID: UUID().uuidString, client: client, startedAt: .now, endedAt: .now, userMessages: ["Fix the build"],
            userMessageCount: 1, toolsUsed: [], skillsUsed: [])
    }

    /// Returns once a scan or a deep dive is waiting to be released.
    func waitUntilHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if !held.isEmpty { return true }
                heldWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseHeld() {
        let waiting = lock.withLock {
            released = true
            let waiting = held
            held = [:]
            return waiting
        }
        for continuation in waiting.values { continuation.resume() }
    }

    private func hold() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (resumeNow, waiters) = lock.withLock {
                    if released || Task.isCancelled { return (true, [CheckedContinuation<Void, Never>]()) }
                    held[id] = continuation
                    let waiters = heldWaiters
                    heldWaiters = []
                    return (false, waiters)
                }
                for waiter in waiters { waiter.resume() }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = lock.withLock { held.removeValue(forKey: id) }
            continuation?.resume()
        }
    }

    func scan(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> InsightsReport {
        lock.withLock { scans.append(options.clients) }
        if holdsScans { await hold() }
        return ShellRenderFixture.insightsReport()
    }

    func scanWithDigests(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> (
        report: InsightsReport, digests: [ConversationDigest]
    ) {
        let report = await scan(options: options, skills: skills, homeURL: homeURL)
        return (report, digests.filter { options.clients.contains($0.client) })
    }

    func deepDive(client: ClientKind, digests: [ConversationDigest], skills: [Skill], windowStart: Date) async throws -> InsightsDeepDive {
        lock.withLock { dives.append(client) }
        if holdsDeepDives { await hold() }
        try Task.checkCancellation()
        return await ShellRenderFixture.insightsDeepDive()
    }

    func lastReport() -> InsightsReport? { lock.withLock { kept } }
    func keep(_ report: InsightsReport) throws { lock.withLock { kept = report } }
    func forget() throws { lock.withLock { kept = nil } }
}
