import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A scan reads and keeps aggregate findings, and a stopped scan is never
/// shown.
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

    @Test func aDeepDiveJoinsTheReportAfterTheFastPassAndIsKept() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let dive = ShellRenderFixture.insightsDeepDive()
        let services = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport(),
            digests: [Self.digest("a"), Self.digest("b")],
            deepDive: .success(dive))
        let session = fixture.insightsSession(services)

        await session.scan(options: .init(clients: [.claude, .kiro]), deepDiveWith: .claude)

        // The fast pass is on screen at once; the assistant is still reading.
        #expect(session.report != nil)
        #expect(session.isScanning == false)
        #expect(session.isDeepDiving == true)
        while session.isDeepDiving { await Task.yield() }

        #expect(session.deepDiveMessage == nil)
        #expect(session.report?.deepDive?.summary == dive.summary)
        #expect(session.report?.deepDive?.recommendations.count == 2)
        #expect(services.deepDiveCalls.map(\.digests) == [2], "every digest is handed over")
        #expect(services.deepDiveCalls.first?.client == .claude)
        #expect(services.keptReport?.deepDive?.summary == dive.summary, "the dive survives a relaunch")
        #expect(session.isDeepDiveStale == false)
    }

    @Test func aDeepDiveThatFailsLeavesTheFastPassAndSaysWhy() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport(),
            digests: [Self.digest("a")],
            deepDive: .failure(InsightsDeepDiveError.clientFailed(.codex, 1, "unexpected status 401 Unauthorized")))
        let session = fixture.insightsSession(services)

        await session.scan(options: .init(clients: [.codex]), deepDiveWith: .codex)
        while session.isDeepDiving { await Task.yield() }

        #expect(session.report != nil)
        #expect(session.report?.deepDive == nil)
        #expect(session.errorMessage == nil, "the fast pass did not fail")
        #expect(session.deepDiveMessage?.contains("401 Unauthorized") == true)
    }

    @Test func aRescanKeepsTheLastDeepDiveUntilANewOneLands() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var restored = ShellRenderFixture.insightsReport()
        restored.deepDive = ShellRenderFixture.insightsDeepDive()
        let services = StubInsightsServices(answer: ShellRenderFixture.insightsReport(), restored: restored)
        let session = fixture.insightsSession(services)
        #expect(session.report?.deepDive != nil)

        await session.scan(options: .init(clients: [.claude]))

        #expect(session.report?.deepDive?.summary == restored.deepDive?.summary)
        #expect(services.deepDiveCalls.isEmpty, "a plain scan asks no assistant")
    }

    @Test func theDailyRunHappensOnlyWhenTheLastDiveIsStale() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var fresh = ShellRenderFixture.insightsReport()
        fresh.deepDive = ShellRenderFixture.insightsDeepDive(at: .now.addingTimeInterval(-3_600))
        let freshServices = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport(), restored: fresh, digests: [Self.digest("a")],
            deepDive: .success(ShellRenderFixture.insightsDeepDive()))
        let freshSession = fixture.insightsSession(freshServices)

        await freshSession.runScheduledDeepDiveIfStale(options: .init(clients: [.claude]), managedClients: [.claude, .codex])

        #expect(freshServices.scanCount == 0, "an hour-old deep dive is not redone")
        #expect(freshServices.deepDiveCalls.isEmpty)

        var stale = ShellRenderFixture.insightsReport()
        stale.deepDive = ShellRenderFixture.insightsDeepDive(at: .now.addingTimeInterval(-25 * 3_600))
        let staleServices = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport(), restored: stale, digests: [Self.digest("a")],
            deepDive: .success(ShellRenderFixture.insightsDeepDive()))
        let staleSession = fixture.insightsSession(staleServices)

        await staleSession.runScheduledDeepDiveIfStale(options: .init(clients: [.claude]), managedClients: [.codex, .claude])
        while staleSession.isDeepDiving { await Task.yield() }

        #expect(staleServices.scanCount == 1)
        #expect(staleServices.deepDiveCalls.first?.client == .claude, "Claude Code is preferred when this Mac has it")

        // A Mac managing only Kiro has no assistant to run one in.
        let kiroOnly = fixture.insightsSession(StubInsightsServices(answer: ShellRenderFixture.insightsReport()))
        await kiroOnly.runScheduledDeepDiveIfStale(options: .init(clients: [.kiro]), managedClients: [.kiro])
        #expect(kiroOnly.report == nil)
        #expect(WorkspaceInsightsSession.deepDiveClient(managed: [.kiro, .codex]) == .codex)
    }

    @Test func stoppingAScanAlsoStopsTheDeepDive() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let services = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport(), holdFor: .seconds(30), digests: [Self.digest("a")],
            deepDive: .success(ShellRenderFixture.insightsDeepDive()))
        let session = fixture.insightsSession(services)

        let scanning = Task { await session.scan(options: .init(clients: [.claude]), deepDiveWith: .claude) }
        while !session.isScanning { await Task.yield() }
        session.cancelScan()
        await scanning.value

        #expect(session.isDeepDiving == false)
        #expect(session.report == nil)
    }

    private static func digest(_ id: String) -> ConversationDigest {
        ConversationDigest(
            conversationID: id, client: .claude, startedAt: .now, endedAt: .now, userMessages: ["fix the build"],
            userMessageCount: 1, toolsUsed: ["Bash"], skillsUsed: [])
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

    /// Catalog suggestions are offered only where there is a catalog to ask.
    ///
    /// The live services reach the catalogs this build ships, so the switch on
    /// the scan options can be turned on; a build handed none says so, and the
    /// switch stays off rather than promising a question with nowhere to go.
    @Test func catalogSuggestionsAreOfferedOnlyWhenACatalogCanBeAsked() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let withCatalogs = LiveInsightsServices(container: fixture.root)
        let withNone = LiveInsightsServices(container: fixture.root, providers: [])

        #expect(withCatalogs.canReachCatalog == !MarketplaceProviderRegistry.builtIn().isEmpty)
        #expect(withNone.canReachCatalog == false)
        // A stub that says nothing about catalogs is treated as reaching none.
        #expect(fixture.insightsSession(StubInsightsServices(answer: ShellRenderFixture.insightsReport())).canReachCatalog == false)
    }

    /// A scan sends its question to the catalogs the services were built with,
    /// and to nothing else. The stub answers from memory, so this never leaves
    /// the machine running it.
    @Test func aScanAsksTheCatalogsItWasGivenWhenSuggestionsAreOn() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let catalog = StubMarketplaceProvider()
        let services = LiveInsightsServices(container: fixture.root, providers: [catalog])
        let session = fixture.insightsSession(services)

        #expect(services.canReachCatalog)
        await session.scan(
            options: .init(clients: [], lookbackDays: 1, includeMarketplaceRecommendations: true))

        // The scan finished over an empty history without touching a client,
        // and the report it saved is the one on screen.
        #expect(session.report != nil)
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
    }
}

extension ShellRenderFixture {
    func insightsSession(_ services: any InsightsServicing) -> WorkspaceInsightsSession {
        WorkspaceInsightsSession(library: workspace.library, homeRoot: home, services: services)
    }
}

/// The scan enriches a library-authored skill with the real description and
/// files read from its content, so the health checks judge what the SKILL.md
/// says rather than the projection's empty placeholders.
@MainActor
struct WorkspaceInsightsSessionEnrichmentTests {
    @Test func aLibrarySkillWithADigestIsEnrichedFromContentBeforeScanning() async throws {
        let harness = try await DigestedLibraryHarness().prepared()
        defer { harness.remove() }
        let skillID = harness.skillID.rawValue.uuidString.lowercased()
        let facts = SkillContentFacts(
            description: "Captures review notes and organizes them into a shareable summary.",
            files: ["SKILL.md", "references/reference.md"])
        let services = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport(),
            contentFacts: [skillID: facts])
        let session = WorkspaceInsightsSession(
            library: harness.library, homeRoot: harness.home, services: services)

        await session.scan(options: .init(clients: []))

        // The session asked for exactly the digested library skill's content.
        #expect(services.lastContentRequests.map(\.skillID) == [skillID])
        #expect(services.lastContentRequests.first?.digest == harness.digest)
        // And it applied the facts to the skill it scanned: the real
        // description and the real file list, not the empty placeholders.
        let scanned = try #require(services.lastScannedSkills.first { $0.id == skillID })
        #expect(scanned.summary == facts.description)
        #expect(scanned.files == facts.files)
        // The files came from reading the captured tree, so the inventory is
        // known and the missing-file check may now judge it.
        #expect(scanned.filesKnown)
    }

    @Test func aLibrarySkillWithNoContentFactsKeepsItsUnknownPlaceholders() async throws {
        let harness = try await DigestedLibraryHarness().prepared()
        defer { harness.remove() }
        let skillID = harness.skillID.rawValue.uuidString.lowercased()
        // The content read returns nothing (an unreadable or absent tree): the
        // skill must stay honestly unknown rather than being invented.
        let services = StubInsightsServices(answer: ShellRenderFixture.insightsReport())
        let session = WorkspaceInsightsSession(
            library: harness.library, homeRoot: harness.home, services: services)

        await session.scan(options: .init(clients: []))

        let scanned = try #require(services.lastScannedSkills.first { $0.id == skillID })
        #expect(scanned.summary.isEmpty)
        #expect(scanned.files.isEmpty)
        // No tree was read, so the inventory stays unknown and the missing-file
        // check must not treat the empty list as a real absence.
        #expect(!scanned.filesKnown)
    }
}

/// A minimal real workspace whose one library skill pins content by digest, so
/// the insights session builds a content request for it. Separate from the
/// shared render fixture, whose standalone skill intentionally has no digest.
@MainActor
final class DigestedLibraryHarness {
    let root: URL
    let home: URL
    let store: WorkspaceRevisionStore
    let library: WorkspaceLibrarySession
    let skillID = ArtifactID()
    let digest = ContentDigest(value: String(repeating: "b", count: 64))

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "insights-enrich-\(UUID())", directoryHint: .isDirectory)
        let container = root.appending(path: "store", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        for directory in [container, home] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(),
            revision: .init(writerID: WorkspaceObjectID()),
            artifacts: [
                .init(
                    identity: .init(id: skillID, kind: .skill, displayName: "Review Notes"),
                    authority: .centralPersonal, declaredName: "review-notes", contentDigest: digest)
            ]))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        store = try WorkspaceRevisionStore(
            containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        let service = WorkspaceApplicationService(store: store, writerID: WorkspaceObjectID())
        library = WorkspaceLibrarySession(
            service: service, workspaceID: store.workspaceID, deviceID: store.deviceID, access: .writable)
    }

    func prepared() async -> DigestedLibraryHarness {
        await library.refresh()
        return self
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
