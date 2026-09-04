import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct WorkspaceEntityStoreTests {
    @Test func normalizedEntityTablesPersistAndListIndependentRecords() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-entities-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let first = SourceLock(revision: "abc", digest: "sha256:first")
        let second = SourceLock(revision: "def", digest: "sha256:second")

        try store.saveEntity(second, id: "source-b", domain: .sourceLocks)
        try store.saveEntity(first, id: "source-a", domain: .sourceLocks)

        let loaded = try store.loadEntity("source-a", domain: .sourceLocks, as: SourceLock.self)
        let listed = try store.listEntities(domain: .sourceLocks, as: SourceLock.self)
        #expect(loaded == first)
        #expect(listed == [first, second])

        try store.removeEntity("source-a", domain: .sourceLocks)
        #expect(try store.loadEntity("source-a", domain: .sourceLocks, as: SourceLock.self) == nil)
    }

    @Test func operationHistoryPruningKeepsOnlyReceiptBackedPlansAndRollbackCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OperationHistoryPruning-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let keptStep = OperationStep(kind: .writeFile, title: "Kept", detail: "Kept by a receipt.")
        let removedStep = OperationStep(kind: .writeFile, title: "Removed", detail: "No retained receipt.")
        let kept = OperationPlan(kind: .configureMCP, title: "Kept", summary: "Kept", steps: [keptStep])
        let removed = OperationPlan(kind: .configureMCP, title: "Removed", summary: "Removed", steps: [removedStep])
        try store.saveEntity(kept, id: kept.id.uuidString.lowercased(), domain: .plans)
        try store.saveEntity(removed, id: removed.id.uuidString.lowercased(), domain: .plans)

        let rollbackRoot = store.receiptsURL.appending(path: "rollback", directoryHint: .isDirectory)
        let keptRollback = rollbackRoot.appending(path: keptStep.id.uuidString, directoryHint: .isDirectory)
        let removedRollback = rollbackRoot.appending(path: removedStep.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: keptRollback, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removedRollback, withIntermediateDirectories: true)

        try store.pruneOperationHistory(keepingPlanIDs: [kept.id])

        let plans = try store.listEntities(domain: .plans, as: OperationPlan.self)
        #expect(plans.map(\.id) == [kept.id])
        #expect(FileManager.default.fileExists(atPath: keptRollback.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: removedRollback.path(percentEncoded: false)))
    }

    @Test func everyNormalizedDomainIsAvailableAfterMigration() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-domains-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)

        for domain in WorkspaceEntityDomain.allCases {
            try store.saveEntity(["domain": domain.rawValue], id: "fixture", domain: domain)
            let value = try store.loadEntity("fixture", domain: domain, as: [String: String].self)
            #expect(value?["domain"] == domain.rawValue)
        }
    }

    @Test func populatedLegacyStoreIsBackedUpBeforeNormalizedMigration() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try WorkspaceStore(rootURL: root)
            try store.save(["legacy": true], for: "workspace.snapshot")
        }
        let databaseURL = root.appending(path: "agent-tooling.sqlite")
        try executeSQL("DELETE FROM schema_migrations WHERE version = 3", at: databaseURL)

        _ = try WorkspaceStore(rootURL: root)

        let backupURL = root.appending(path: "agent-tooling.pre-migration-v3.sqlite")
        #expect(FileManager.default.fileExists(atPath: backupURL.path(percentEncoded: false)))
        let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func normalizedWorkspaceIsAuthoritativeOverCompatibilityShadow() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-normalized-snapshot-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let profile = ToolingProfile(
            id: "team",
            name: "Team",
            summary: "Fixture",
            checks: [],
            enabledPlugins: [],
            requiredMCPs: []
        )
        let source = ToolingSource(name: "Local", kind: .localFolder, location: "/tmp/fixture")
        let snapshot = WorkspaceSnapshot(profiles: [profile], sources: [source], activeProfileID: "team")

        try store.saveWorkspaceSnapshot(snapshot)
        try store.save(WorkspaceSnapshot(), for: "workspace.snapshot")
        let loaded = try #require(try store.loadWorkspaceSnapshot())

        #expect(loaded.profiles.map(\.id) == ["team"])
        #expect(loaded.sources.map(\.name) == ["Local"])
        #expect(loaded.activeProfileID == "team")
    }

    @Test func workspaceSnapshotsUseStableSemanticEntityIDs() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-stable-ids-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let sourceID = UUID()
        let source = ToolingSource(id: sourceID, name: "Fixture", kind: .localFolder, location: "/tmp/fixture")
        let lock = SourceLock(revision: "abc123", digest: "sha256:fixture")
        let package = MarketplacePackage(
            id: "fixture.package",
            name: "Fixture",
            publisher: "Tests",
            summary: "Stable identifier fixture",
            sourceName: "Fixture",
            components: [.skill],
            supportedClients: [.codex],
            location: "/tmp/fixture/package",
            provenance: PackageProvenance(
                source: PackageSource(kind: .localFolder, location: "/tmp/fixture"),
                lock: lock
            )
        )

        try store.saveWorkspaceSnapshot(WorkspaceSnapshot(sources: [source], marketplacePackages: [package]))

        let storedSource = try store.loadEntity(
            sourceID.uuidString.lowercased(),
            domain: .sources,
            as: ToolingSource.self
        )
        let storedLock = try store.loadEntity(
            "marketplace:fixture.package",
            domain: .sourceLocks,
            as: SourceLock.self
        )
        #expect(storedSource == source)
        #expect(storedLock == lock)
    }

    @Test func blobOnlyWorkspaceMigratesOnFirstNormalizedLoad() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-legacy-snapshot-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let snapshot = WorkspaceSnapshot(
            sources: [ToolingSource(name: "Legacy", kind: .localFolder, location: "/tmp/legacy")]
        )
        try store.save(snapshot, for: "workspace.snapshot")

        let loaded = try #require(try store.loadWorkspaceSnapshot())
        try store.save(WorkspaceSnapshot(), for: "workspace.snapshot")
        let loadedAgain = try #require(try store.loadWorkspaceSnapshot())

        #expect(loaded.sources.map(\.name) == ["Legacy"])
        #expect(loadedAgain.sources.map(\.name) == ["Legacy"])
    }

    private func executeSQL(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK, let database else {
            throw WorkspaceStoreError.openDatabase(databaseURL.path(percentEncoded: false))
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw WorkspaceStoreError.query(String(cString: sqlite3_errmsg(database)))
        }
    }
}
