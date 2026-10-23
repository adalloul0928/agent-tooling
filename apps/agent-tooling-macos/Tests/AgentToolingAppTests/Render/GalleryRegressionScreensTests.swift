import AgentToolingTestSupport
import Foundation
import SQLite3
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Repaired Activity and History states and populated App Settings, with their
/// actual content verified through accessibility before a frame is written.
@Suite("Gallery · Regression screens", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryRegressionScreensTests {
    private static let both: [RenderAppearance] = [.light, .dark]

    /// Reads only the synthetic home and explicitly excludes any live Mac
    /// policy path. The view's own refresh must settle before rows are captured.
    @Test func appSettingsPopulated() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture(
                deviceObserver: StubDeviceObserver(observations: [
                    ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.0.0"),
                    ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true, version: "0.140.0"),
                ]))
            defer { fixture.remove() }
            for name in [".claude", ".codex"] {
                try FileManager.default.createDirectory(
                    at: fixture.home.appending(path: name), withIntermediateDirectories: true)
            }
            try Data(#"{"model":"opus","cleanupPeriodDays":30,"hooks":[]}"#.utf8)
                .write(to: fixture.home.appending(path: ".claude/settings.json"))
            try Data("model = \"gpt-5\"\nmodel_reasoning_effort = \"high\"\n".utf8)
                .write(to: fixture.home.appending(path: ".codex/config.toml"))
            await fixture.workspace.device.refresh()
            await fixture.workspace.library.refresh()
            let session = WorkspaceSettingsSession(
                homeRoot: fixture.home, library: fixture.workspace.library, managedPolicyPath: .some(nil))
            await session.refresh(managedClients: [.claude, .codex])
            #expect(session.surfaces.allSatisfy { $0.errorMessage == nil })
            #expect(session.surfaces.contains { $0.configuration?.rows.contains { $0.key == "model" } == true })

            try await galleryShellSnapshot(
                EffectiveSettingsView(session: session).environment(\.availableClients, [.claude, .codex]),
                area: "Apps · App settings", screen: "App settings", state: "populated-configuration",
                appearance: appearance, source: "Sources/AgentToolingApp/EffectiveSettingsView.swift",
                note: "populated section content in a fixture window; synthetic Claude/Codex files; live managed policy excluded"
            ) { probe in
                let text = Self.text(in: probe)
                return session.hasLoaded && !session.isBusy && text.contains("opus") && text.contains("gpt-5")
                    && !probe.contains("Reading app settings…")
            }
        }
    }

    @Test func activitySelectedRemovalReceipt() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            let stepID = fixtureUUID("00000000-0000-0000-0000-000000000041")
            let recovery = "/tmp/agent-tooling-fixture/recovery/removed-skill"
            let original = "/tmp/agent-tooling-fixture/home/.claude/skills/removed-skill"
            let output =
                String(repeating: "Reviewed local removal. ", count: 15)
                + "\nRecovery folder: \(recovery)\nOriginal destination: \(original)"
            let receipt = OperationReceipt(
                planID: UUID(), kind: .installSkill, title: "Remove a managed skill", state: .healthy,
                targetSurfaces: [.claudeCode],
                results: [
                    .init(
                        stepID: stepID, status: .succeeded, output: output, startedAt: ClientHomeFixture.now,
                        finishedAt: ClientHomeFixture.now)
                ],
                createdAt: ClientHomeFixture.now, verificationSummary: "Removed with a recovery copy.",
                itemOutcomes: [
                    .init(
                        id: stepID, title: "Remove managed skill", status: .succeeded,
                        reason: "Removed. Full recovery details are in the receipt.")
                ])
            try fixture.store.recordOperationReceipt(receipt)
            let session = WorkspaceActivitySession(store: fixture.store)
            await session.refresh(driftReader: StubInstallDriftReader())
            let navigation = AppNavigationState()
            navigation.openItem(receipt.id.uuidString, in: .activity)

            try await galleryShellSnapshot(
                ActivityView(session: session).environment(navigation).environment(\.installDriftReader, StubInstallDriftReader()),
                area: "Activity", screen: "Activity receipt", state: "selected-removal-recovery",
                appearance: appearance, source: "Sources/AgentToolingApp/ActivityView.swift",
                note: "synthetic stored receipt; output exceeds the former 320-character summary limit; no removal was executed"
            ) { probe in
                let text = Self.text(in: probe)
                return probe.contains("Activity details") && text.contains(recovery) && text.contains(original)
            }
        }
    }

    @Test func activityReadFailure() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try fixture.store.saveActivityJournal("Unreadable synthetic fixture journal")
            let session = WorkspaceActivitySession(store: fixture.store)
            await session.refresh(driftReader: StubInstallDriftReader())
            #expect(session.errorMessage != nil)

            try await galleryShellSnapshot(
                ActivityView(session: session).environment(AppNavigationState()).environment(
                    \.installDriftReader, StubInstallDriftReader()),
                area: "Activity", screen: "Activity", state: "read-failure",
                appearance: appearance, source: "Sources/AgentToolingApp/ActivityView.swift",
                note: "isolated fixture journal has an intentionally incompatible payload; retry is visible"
            ) { probe in
                probe.contains("Activity could not be read") && probe.button("Try again") != nil
            }
        }
    }

    @Test func historySelectedRestorePreview() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            let original = try #require(try fixture.store.snapshot()).document.revision.id
            try await fixture.addRequestedPackage()
            await fixture.workspace.history.refresh()
            fixture.workspace.history.select(original)
            #expect(fixture.workspace.history.preview?.isEmpty == false)

            try await galleryShellSnapshot(
                HistorySection(workspace: fixture.workspace),
                area: "History", screen: "History", state: "selected-restore-preview",
                appearance: appearance, source: "Sources/AgentToolingApp/Sections/HistorySection.swift",
                note: "synthetic library before a package assignment; preview only, no restore was applied"
            ) { probe in
                probe.contains("Going back to this version would make these changes to your library.")
                    && probe.button("Go back to this version…") != nil
                    && !fixture.workspace.history.isBusy
            }
        }
    }

    @Test func historyReadFailure() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try corruptFixtureHead(in: fixture.store)
            await fixture.workspace.history.refresh()
            #expect(fixture.workspace.history.errorMessage != nil)

            try await galleryShellSnapshot(
                HistorySection(workspace: fixture.workspace),
                area: "History", screen: "History", state: "read-failure",
                appearance: appearance, source: "Sources/AgentToolingApp/Sections/HistorySection.swift",
                note: "isolated fixture head has an intentionally invalid payload; retry is visible"
            ) { probe in
                probe.contains("History could not be read") && probe.button("Try again") != nil
                    && !fixture.workspace.history.isBusy
            }
        }
    }

    private static func text(in probe: AccessibilityProbe) -> String {
        probe.elements.flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
    }

    /// Mirrors the error fixture used by the regression test. Only this
    /// disposable fixture database is changed, never a real workspace.
    private func corruptFixtureHead(in store: WorkspaceRevisionStore) throws {
        var database: OpaquePointer?
        guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK, let database else {
            throw WorkspaceRevisionStoreError.databaseUnavailable
        }
        defer { sqlite3_close(database) }
        // Simulate on-disk corruption in this disposable fixture, outside the
        // store's normal immutable-revision write guard.
        guard sqlite3_exec(database, "DROP TRIGGER IF EXISTS revisions_immutable_update", nil, nil, nil) == SQLITE_OK else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "UPDATE revisions SET payload = ? WHERE id = (SELECT revision_id FROM workspace_head)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        let data = Data([0])
        let status = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw WorkspaceRevisionStoreError.corruptState
        }
    }
}
