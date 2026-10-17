import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The journal, the receipts and the drift a workspace's own store already
/// holds — read back, never written here, and never touching a real path on
/// disk for drift, which is why every test injects a reader.
@MainActor
struct WorkspaceActivitySessionTests {
    @Test func aFreshWorkspaceHasNoActivityAndNoError() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = WorkspaceActivitySession(store: fixture.store)

        await session.refresh(driftReader: StubInstallDriftReader())

        #expect(session.receipts.isEmpty)
        #expect(session.activities.isEmpty)
        #expect(session.drift.isEmpty)
        #expect(session.errorMessage == nil)
        #expect(!session.isBusy)
    }

    @Test func refreshReadsBackWhatTheStoreAlreadyHolds() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let receipt = try fixture.seedActivity()
        let session = WorkspaceActivitySession(store: fixture.store)
        let drift = InstalledPackageDrift(
            destinationPath: "/tmp/example/skills/example",
            packageName: "example",
            state: .modifiedSinceReview,
            reviewedFingerprint: "abc123",
            reviewedAt: .now)

        await session.refresh(driftReader: StubInstallDriftReader(reports: [drift]))

        #expect(session.receipts.map(\.id) == [receipt.id])
        #expect(session.activities.map(\.title) == ["Installed Example Skill"])
        #expect(session.activities.first?.operationReceiptID == receipt.id)
        #expect(session.drift == [drift])
    }

    /// The item outcomes on the receipt behind an activity entry stay
    /// reachable, skipped step and its reason included, so a person can see
    /// why a batch was only partly applied.
    @Test func theOperationReceiptBehindAnActivityEntryKeepsItsItemOutcomes() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let receipt = try fixture.seedActivity()
        let session = WorkspaceActivitySession(store: fixture.store)
        await session.refresh(driftReader: StubInstallDriftReader())

        let linked = try #require(session.operationReceipt(for: receipt.id))

        #expect(linked.itemOutcomes.count == 2)
        #expect(linked.itemOutcomes.contains { $0.status == .skipped && $0.reason == "Already up to date." })
    }

    /// A receipt with no matching id, and a nil id, both answer nothing rather
    /// than crashing or returning an arbitrary receipt.
    @Test func operationReceiptLookupIsNilSafeAndMissSafe() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try fixture.seedActivity()
        let session = WorkspaceActivitySession(store: fixture.store)
        await session.refresh(driftReader: StubInstallDriftReader())

        #expect(session.operationReceipt(for: nil) == nil)
        #expect(session.operationReceipt(for: UUID()) == nil)
    }

    /// The default reader is the live one, and on a workspace that never
    /// recorded an install, it has nothing to check — so exercising the real
    /// default here still touches no path outside the fixture's own scratch
    /// directory.
    @Test func theLiveDefaultReaderReadsNothingWhenNothingWasInstalled() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = WorkspaceActivitySession(store: fixture.store)

        await session.refresh()

        #expect(session.drift.isEmpty)
    }

    /// The live reader reports the whole comparison, not half of it: an install
    /// that is gone, and one that is still there but no longer matches the
    /// fingerprint recorded when it was approved. Both paths stay inside the
    /// fixture's own scratch directory, never a real install location.
    @Test func theLiveDefaultReaderReportsBothRemovedAndModifiedInstalls() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let stillThere = fixture.root.appending(path: "still-there", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stillThere, withIntermediateDirectories: true)
        var ledger = ManagedInstallLedger()
        ledger.upsert(
            ManagedInstallRecord(
                destinationPath: fixture.root.appending(path: "gone").path,
                sourcePath: "/does/not/matter",
                reviewedFingerprint: "abc",
                reviewedAt: .now))
        ledger.upsert(
            ManagedInstallRecord(
                destinationPath: stillThere.path,
                sourcePath: "/does/not/matter",
                reviewedFingerprint: "def",
                reviewedAt: .now))
        try ledger.save(to: fixture.store)
        let session = WorkspaceActivitySession(store: fixture.store)

        await session.refresh()

        let states = Dictionary(
            uniqueKeysWithValues: session.drift.map { ($0.packageName, $0.state) })
        #expect(states["gone"] == .removed)
        // "def" is not this folder's fingerprint, so the copy on disk no longer
        // matches what was approved — which is drift, and is now reported.
        #expect(states["still-there"] == .modifiedSinceReview)
    }

    /// A store holding one operation receipt and an empty journal shows one
    /// row, titled from the plan — the case the old screen showed as "No
    /// activity yet" while Apps → Recent changes listed the very same install.
    @Test func oneOperationReceiptWithAnEmptyJournalBecomesOneMergedRow() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let receipt = OperationReceipt(
            planID: UUID(),
            kind: .installSkill,
            title: "Install 1 tool in Claude Code",
            state: .healthy,
            targetSurfaces: [.claudeCode],
            results: [],
            createdAt: .now,
            verificationSummary: "Installed for Claude Code.",
            itemOutcomes: [
                OperationItemOutcome(id: UUID(), title: "Review Notes", status: .succeeded, reason: "Copied into place.")
            ])
        try fixture.store.recordOperationReceipt(receipt)
        let session = WorkspaceActivitySession(store: fixture.store)

        await session.refresh(driftReader: StubInstallDriftReader())

        // The journal is empty, but the merged list is not: the receipt becomes
        // one row titled from the plan and pointing back at itself.
        #expect(session.activities.isEmpty)
        #expect(session.mergedActivities.count == 1)
        let row = try #require(session.mergedActivities.first)
        #expect(row.title == "Install 1 tool in Claude Code")
        #expect(row.detail == receipt.outcomeTally)
        #expect(row.kind == .configuration)
        #expect(row.state == .healthy)
        #expect(row.operationReceiptID == receipt.id)
    }

    /// A journal entry that already links a receipt speaks for it, so that
    /// receipt is not synthesized a second time: one receipt, one row.
    @Test func aJournalEntryReferencingAReceiptIsNotDuplicated() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let receipt = try fixture.seedActivity()
        let session = WorkspaceActivitySession(store: fixture.store)

        await session.refresh(driftReader: StubInstallDriftReader())

        #expect(session.mergedActivities.count == 1)
        // The one row is the journal entry, not the synthesized receipt.
        #expect(session.mergedActivities.first?.title == "Installed Example Skill")
        #expect(session.mergedActivities.first?.operationReceiptID == receipt.id)
    }

    /// A receipt with no journal entry AND a journal entry with no receipt both
    /// appear, newest first — nothing is dropped from either source.
    @Test func mergedActivityCombinesBothSourcesNewestFirst() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let now = Date.now
        let standaloneReceipt = OperationReceipt(
            planID: UUID(), kind: .doctor, title: "Run setup check", state: .healthy,
            targetSurfaces: [.claudeCode], results: [], createdAt: now,
            verificationSummary: "All good.")
        try fixture.store.recordOperationReceipt(standaloneReceipt)
        let journal = AgentActivityJournal(entries: [
            ActivityReceipt(
                kind: .configuration, title: "Agent searched the inventory",
                detail: "Read-only.", date: now.addingTimeInterval(-60), state: .healthy)
        ])
        try fixture.store.saveActivityJournal(journal)
        let session = WorkspaceActivitySession(store: fixture.store)

        await session.refresh(driftReader: StubInstallDriftReader())

        #expect(session.mergedActivities.count == 2)
        // Newest first: the receipt (now) leads the journal entry (a minute ago).
        #expect(session.mergedActivities.first?.title == "Run setup check")
        #expect(session.mergedActivities.last?.title == "Agent searched the inventory")
    }
}
