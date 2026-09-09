import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceSchemaCompatibilityTests {
    @Test func revisionStoreRetainsConfigurationReferencesAcrossMetadataEditsAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "schema-two-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactID = ArtifactID()
        let configurationID = WorkspaceObjectID()
        let skillKey = LegacyReferenceKey(domain: .skill, identifier: "sample")
        let configurationKey = LegacyReferenceKey(domain: .configuration, identifier: "my-setup")
        let writerID = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            revision: .init(writerID: writerID),
            artifacts: [.init(identity: .init(id: artifactID, kind: .skill, displayName: "Sample"), authority: .trackedOnly)],
            configurationState: .init(
                configurations: [.init(id: configurationID, name: "My setup", requiredSkills: [.init(legacy: skillKey, resolution: .artifact(artifactID))], targetBindings: [])],
                identityMap: [.init(legacy: skillKey, objectID: WorkspaceObjectID(artifactID.rawValue)), .init(legacy: configurationKey, objectID: configurationID)])))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID,
            configurationState: .init(activeConfigurationOverrideID: configurationID))
        let store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        let service = WorkspaceApplicationService(store: store, writerID: writerID)
        let receipt = try await service.renameArtifact(.init(expectedRevisionID: document.revision.id, artifactID: artifactID, displayName: "Renamed"))
        let reopened = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        let saved = try #require(try reopened.snapshot())
        #expect(saved.document.revision.id == receipt.committedRevisionID)
        #expect(saved.document.configurationState == document.configurationState)
        #expect(saved.device == device)
        #expect(saved.document.artifacts.first?.identity.displayName == "Renamed")
        #expect(try reopened.revision(document.revision.id) == document)
    }

    @Test func originalPortableWireRemainsReadableAndByteStable() throws {
        let original = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            schemaVersion: 1, minimumReaderVersion: 1, minimumWriterVersion: 1,
            revision: .init(writerID: WorkspaceObjectID()), configurationState: nil))
        let encoded = try WorkspaceDocumentCoding.encode(original)
        let decoded = try WorkspaceDocumentCoding.decode(encoded)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.configurationState == nil)
        #expect(try WorkspaceDocumentCoding.encode(decoded) == encoded)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("configurationState"))
    }

    @Test func fixedSchemaTwoWireAndDigestRemainStableAfterSchemaThree() throws {
        let workspaceID = WorkspaceObjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let revisionID = WorkspaceObjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let writerID = WorkspaceObjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        let createdAt = Date(timeIntervalSince1970: 1_767_323_045.678)
        let expectedDigest = "6212c3683c14a47e998298e74696c35d79dd09e82e59d8b56bb7eaa6adca943a"
        let expectedBytes = """
        {"artifacts":[],"assignments":[],"configurationState":{"catalogSources":[],"collections":[],"configurations":[],"identityMap":[],"legacyRelationships":[],"managedPolicies":[],"tagAssignments":[]},"logicalProjects":[],"minimumReaderVersion":2,"minimumWriterVersion":2,"presets":[],"revision":{"createdAt":"2026-01-02T03:04:05.678Z","documentDigest":{"algorithm":"sha256CanonicalJSONV1","value":"6212c3683c14a47e998298e74696c35d79dd09e82e59d8b56bb7eaa6adca943a"},"id":"00000000-0000-0000-0000-000000000011","parentIDs":[],"writerID":"00000000-0000-0000-0000-000000000012"},"schemaVersion":2,"sources":[],"subscriptions":[],"tombstones":[],"workspaceID":"00000000-0000-0000-0000-000000000010"}
        """
        let document = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            schemaVersion: 2, minimumReaderVersion: 2, minimumWriterVersion: 2,
            workspaceID: workspaceID,
            revision: .init(id: revisionID, writerID: writerID, createdAt: createdAt),
            configurationState: .init()))

        #expect(document.revision.documentDigest.value == expectedDigest)
        #expect(try WorkspaceDocumentCoding.digest(for: document).value == expectedDigest)
        #expect(try WorkspaceDocumentCoding.encode(document) == Data(expectedBytes.utf8))
        #expect(try WorkspaceDocumentCoding.decode(Data(expectedBytes.utf8)) == document)
    }

    @Test func versionTwoFeaturesCannotBeWrittenAsVersionOne() throws {
        var document = PortableWorkspaceDocument(schemaVersion: 2, minimumReaderVersion: 2, minimumWriterVersion: 2,
            revision: .init(writerID: WorkspaceObjectID()))
        #expect(document.schemaVersion == 2)
        #expect(document.configurationState != nil)
        let encoded = try WorkspaceDocumentCoding.encode(WorkspaceDocumentCoding.seal(document))
        #expect(try WorkspaceDocumentCoding.decode(encoded).configurationState == WorkspaceConfigurationState())

        document.minimumReaderVersion = 1
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(document) }
        document.minimumReaderVersion = 2
        document.minimumWriterVersion = 1
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(document) }
        document.minimumWriterVersion = 2
        document.configurationState = nil
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(document) }
        document.schemaVersion = 1
        document.minimumReaderVersion = 1
        document.minimumWriterVersion = 1
        document.configurationState = .init()
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(document) }
    }

    @Test func oldDeviceBytesRemainReadableAndUnknownFeaturesAreRejected() throws {
        let old = DeviceWorkspaceState(schemaVersion: 1, workspaceID: WorkspaceObjectID(), configurationState: nil)
        let encoded = try WorkspaceDocumentCoding.encodeDeviceState(old)
        #expect(try WorkspaceDocumentCoding.decodeDeviceState(encoded) == old)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("configurationState"))

        let text = String(decoding: encoded, as: UTF8.self)
        let unknown = Data(text.replacingOccurrences(of: "{\"", with: "{\"futureDeviceFeature\":true,\"", options: [], range: text.startIndex..<text.index(text.startIndex, offsetBy: 2)).utf8)
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.decodeDeviceState(unknown) }
        var invalid = old
        invalid.configurationState = .init()
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.encodeDeviceState(invalid) }
    }

    @Test func deviceConfigurationChoicesDoNotChangePortableDigest() throws {
        let configurationID = WorkspaceObjectID()
        let catalogID = WorkspaceObjectID()
        let configKey = LegacyReferenceKey(domain: .configuration, identifier: "local-library")
        let catalogKey = LegacyReferenceKey(domain: .catalogSource, identifier: catalogID.rawValue.uuidString.lowercased())
        let state = WorkspaceConfigurationState(
            configurations: [.init(id: configurationID, name: "My setup", checkDefinitions: [.init(id: "apps", name: "App status")])],
            catalogSources: [.init(id: catalogID, name: "My sources", kind: .localFolder)],
            identityMap: [.init(legacy: configKey, objectID: configurationID), .init(legacy: catalogKey, objectID: catalogID)])
        let portable = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            revision: .init(writerID: WorkspaceObjectID()), configurationState: state))
        let digest = portable.revision.documentDigest
        var device = DeviceWorkspaceState(workspaceID: portable.workspaceID, configurationState: .init(
            activeConfigurationOverrideID: configurationID,
            configurationBindings: [.init(configurationID: configurationID, projectRoot: "/private/machine-a/project")],
            checkObservations: [.init(configurationID: configurationID, checkID: "apps", detail: "Local result", state: .healthy)],
            catalogSources: [.init(catalogSourceID: catalogID, localLocation: "/private/machine-a/catalog", trustSummary: "Checked locally")]))
        try device.validateStructure(against: portable)
        let bytes = try WorkspaceDocumentCoding.encodeDeviceState(device)
        #expect(try WorkspaceDocumentCoding.decodeDeviceState(bytes, against: portable) == device.canonicalized())
        device.configurationState?.activeConfigurationOverrideID = nil
        device.configurationState?.configurationBindings[0].projectRoot = "/private/machine-b/project"
        try device.validateStructure(against: portable)
        #expect(try WorkspaceDocumentCoding.digest(for: portable) == digest)
        #expect(!String(decoding: try WorkspaceDocumentCoding.encode(portable), as: UTF8.self).contains("machine-a"))

        device.configurationState?.activeConfigurationOverrideID = WorkspaceObjectID()
        #expect(throws: WorkspaceDomainValidationError.self) { try device.validateStructure(against: portable) }
        device.configurationState?.activeConfigurationOverrideID = nil
        device.configurationState?.checkObservations[0].checkID = "deleted-check"
        #expect(throws: WorkspaceDomainValidationError.self) { try device.validateStructure(against: portable) }
    }
}
