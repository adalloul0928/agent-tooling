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

    /// The live reader can honestly tell a removed install apart from a
    /// present one with only `FileManager`, so it reports that much even
    /// though it cannot yet recompute a fingerprint to tell a present install
    /// apart from a modified one (see `LiveInstallDriftReader`'s own
    /// documentation for why). Both paths stay inside the fixture's own
    /// scratch directory, never a real install location.
    @Test func theLiveDefaultReaderReportsARemovedInstallAndLeavesAPresentOneOut() async throws {
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

        #expect(session.drift.map(\.packageName) == ["gone"])
        #expect(session.drift.first?.state == .removed)
    }
}
