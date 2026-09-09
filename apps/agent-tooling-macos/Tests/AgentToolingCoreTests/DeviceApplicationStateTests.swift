import Foundation
import Testing
@testable import AgentToolingCore

struct DeviceApplicationStateTests {
    @Test func schemaFourRoundTripsApplicationProjectionAndKeepsItLocal() throws {
        let catalogID = UUID()
        let preciseDate = Date(timeIntervalSince1970: 1_788_900_000.123456)
        var snapshot = WorkspaceSnapshot(
            sources: [.init(id: catalogID, name: "Catalog", kind: .localFolder, location: "/device/catalog")],
            marketplacePackages: [.init(id: "package", name: "Package", publisher: "Publisher", summary: "", sourceID: catalogID,
                                        sourceName: "Catalog", components: [.skill], supportedClients: [.codex], location: "/device/package")],
            accountSurfaces: [.init(surface: .codexCloud, name: "Account", status: .verified, guidance: "Verify")],
            connectors: [.init(name: "Connector", provider: "Provider", ownership: .account, description: "", secretReferenceNames: ["TOKEN"], bindings: [])])
        snapshot.importedRepositoryPath = "/device/repository"
        snapshot.activeProfileID = ""
        snapshot.preferences = .init(automaticallyCheckHealth: false, enabledClients: [.codex])
        snapshot.backupConfiguration = .init(isEnabled: true, location: "/device/backup", remoteName: "origin", lastExportAt: preciseDate)
        snapshot.encryptedSyncConfiguration = .init(isEnabled: true, location: "/device/encrypted", lastExportAt: preciseDate, lastImportAt: preciseDate)
        snapshot.activities = [.init(kind: .validation, title: "Checked", detail: "Complete", date: preciseDate, state: .healthy)]
        snapshot.operationReceipts = [.init(planID: UUID(), kind: .scan, title: "Scan", state: .healthy, targetSurfaces: [.codexCLI],
            results: [.init(stepID: UUID(), status: .succeeded, output: "Complete", startedAt: preciseDate, finishedAt: preciseDate)],
            createdAt: preciseDate, verificationSummary: "Complete")]
        snapshot.accountSurfaces[0].lastVerifiedAt = preciseDate
        snapshot.connectors[0].bindings = [.init(target: .codexCloud, scope: .account, guidance: "Verify", lastVerifiedAt: preciseDate)]
        snapshot.marketplacePackages[0].lastUpdate = .init(date: preciseDate, origin: .catalogListing)
        snapshot.marketplacePackages[0].components = [.skill, .plugin, .mcpServer]
        snapshot.marketplacePackages[0].supportedClients = Set(ClientKind.allCases)
        let application = DeviceApplicationState(snapshot: snapshot)
        var projected = WorkspaceSnapshot()
        try application.apply(to: &projected)
        #expect(projected.preferences == snapshot.preferences)
        #expect(projected.importedRepositoryPath == snapshot.importedRepositoryPath)
        #expect(projected.marketplacePackages == snapshot.marketplacePackages)
        #expect(projected.activities == snapshot.activities)
        #expect(projected.operationReceipts == snapshot.operationReceipts)
        #expect(projected.backupConfiguration == snapshot.backupConfiguration)
        #expect(projected.encryptedSyncConfiguration == snapshot.encryptedSyncConfiguration)
        #expect(projected.sources.isEmpty)

        let workspaceID = WorkspaceObjectID()
        let config = try WorkspaceConfigurationMigration.preview(snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [:])
        #expect(config.canMigrateConfigurations)
        let document = try WorkspaceDocumentCoding.seal(.init(workspaceID: workspaceID, revision: .init(writerID: workspaceID),
            configurationState: config.state))
        let device = DeviceWorkspaceState(workspaceID: workspaceID, configurationState: config.deviceState, applicationState: application)
        let bytes = try WorkspaceDocumentCoding.encodeDeviceState(device)
        let decoded = try WorkspaceDocumentCoding.decodeDeviceState(bytes, against: document)
        #expect(decoded.applicationState == application.canonicalized())
        #expect(try WorkspaceDocumentCoding.encodeDeviceState(decoded) == bytes)
        #expect(String(decoding: bytes, as: UTF8.self).contains("applicationState"))
        let root = FileManager.default.temporaryDirectory.appending(path: "device-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
        }
        let reopened = try WorkspaceRevisionStore(containerRoot: root, workspaceID: workspaceID, deviceID: device.deviceID)
        #expect(try reopened.snapshot()?.device == decoded)
    }

    @Test func schemaThreeRemainsWithoutApplicationStateAndMisplacedFieldsFail() throws {
        let state = DeviceWorkspaceState(schemaVersion: 3, workspaceID: WorkspaceObjectID())
        let bytes = try WorkspaceDocumentCoding.encodeDeviceState(state)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("applicationState"))
        #expect(try WorkspaceDocumentCoding.decodeDeviceState(bytes).applicationState == nil)
        var invalid = state
        invalid.applicationState = .init()
        #expect(throws: WorkspaceDomainValidationError.self) { try WorkspaceDocumentCoding.encodeDeviceState(invalid) }
    }

    @Test func applicationRejectsInvalidPathAndUnknownCatalogContext() throws {
        let invalid = DeviceApplicationState(importedRepositoryPath: "relative")
        #expect(throws: WorkspaceSnapshotValidationError.self) { try invalid.validate() }
        let state = DeviceApplicationState(catalogSourceIDs: [UUID()])
        #expect(throws: WorkspaceDomainValidationError.self) { try state.validate(against: .init()) }
        let duplicatePreferences = DeviceApplicationState(preferences: .init(enabledClients: [.codex, .codex]))
        #expect(throws: WorkspaceDomainValidationError.self) { try duplicatePreferences.validate() }
        var untouched = WorkspaceSnapshot(importedRepositoryPath: "/original")
        #expect(throws: WorkspaceDomainValidationError.self) { try duplicatePreferences.apply(to: &untouched) }
        #expect(untouched.importedRepositoryPath == "/original")
    }

    @Test func catalogReferencesRequireLiveMigrationTargetsAndOldPortableRejectsThem() throws {
        let workspaceID = WorkspaceObjectID()
        let sourceID = UUID()
        let snapshot = WorkspaceSnapshot(sources: [.init(id: sourceID, name: "Source", kind: .localFolder, location: "/device/catalog")], activeProfileID: "")
        let config = try WorkspaceConfigurationMigration.preview(snapshot: snapshot, workspaceID: workspaceID, artifactBindings: [:])
        #expect(config.canMigrateConfigurations)
        let application = DeviceApplicationState(snapshot: snapshot)
        try application.validate(against: config.state)
        var stale = config.state
        stale.catalogSources = []
        #expect(throws: WorkspaceDomainValidationError.self) { try application.validate(against: stale) }
        let old = try WorkspaceDocumentCoding.seal(.init(schemaVersion: 1, minimumReaderVersion: 1, minimumWriterVersion: 1, workspaceID: workspaceID,
            revision: .init(writerID: workspaceID), configurationState: nil))
        let device = DeviceWorkspaceState(workspaceID: workspaceID, applicationState: application)
        #expect(throws: WorkspaceDomainValidationError.self) { try device.validateStructure(against: old) }
    }

    @Test func projectRootsRequireUniqueIDsAndAbsolutePaths() throws {
        let project = ArtifactID()
        let state = DeviceWorkspaceState(workspaceID: WorkspaceObjectID(), projectRoots: [
            .init(projectID: project, rootPath: "/work/project"),
            .init(projectID: project, rootPath: "/work/other"),
        ])
        #expect(throws: WorkspaceDomainValidationError.self) { try state.validateStructure() }
        let invalidPath = DeviceWorkspaceState(workspaceID: WorkspaceObjectID(), projectRoots: [
            .init(projectID: ArtifactID(), rootPath: "relative")
        ])
        #expect(throws: WorkspaceDomainValidationError.self) { try invalidPath.validateStructure() }
    }
}
