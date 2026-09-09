import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceMCPDefinitionTests {
    @Test func portableDefinitionsRoundTripAndCanonicalizeByArtifactID() throws {
        let first = ArtifactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = ArtifactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let document = try WorkspaceDocumentCoding.seal(portableDocument(
            artifacts: [personalMCP(second), personalMCP(first)],
            definitions: [
                .init(artifactID: second, connection: .deviceBound(transport: .stdio)),
                .init(artifactID: first, connection: .remoteHTTPS(url: "https://mcp.example.com/v1")),
            ]))

        #expect(document.mcpDefinitions?.map(\.artifactID) == [first, second])
        let bytes = try WorkspaceDocumentCoding.encode(document)
        #expect(String(decoding: bytes, as: UTF8.self).contains("mcpDefinitions"))
        #expect(try WorkspaceDocumentCoding.decode(bytes) == document)
    }

    @Test func portableDefinitionsRejectMissingWrongKindNativeTrackedAndContentArtifacts() throws {
        let identifier = ArtifactID()
        let definition = PortableMCPDefinitionRecord(
            artifactID: identifier, connection: .remoteHTTPS(url: "https://mcp.example.com"))

        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(portableDocument(
                artifacts: [personalMCP(identifier)], definitions: []))
        }
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(portableDocument(artifacts: [], definitions: [definition]))
        }
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(portableDocument(
                artifacts: [.init(identity: .init(id: identifier, kind: .skill, displayName: "Not MCP"), authority: .centralPersonal)],
                definitions: [definition]))
        }
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(portableDocument(
                artifacts: [.init(identity: .init(id: identifier, kind: .mcpServer, displayName: "Tracked"), authority: .trackedOnly)],
                definitions: [definition]))
        }
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(portableDocument(
                artifacts: [.init(
                    identity: .init(id: identifier, kind: .mcpServer, displayName: "Materialized"),
                    authority: .centralPersonal,
                    contentDigest: .init(value: String(repeating: "a", count: 64)))],
                definitions: [definition]))
        }

        let nativeParent = ArtifactID()
        let nativeChild = ArtifactID()
        let nativeArtifacts: [ArtifactRecord] = [
            .init(
                identity: .init(id: nativeParent, kind: .nativePlugin, displayName: "Native"),
                authority: .nativeOwned,
                nativeRoutes: [.init(client: .claude, externalPluginID: "native")]),
            .init(
                identity: .init(id: nativeChild, kind: .mcpServer, displayName: "Native child", parentPackageID: nativeParent),
                authority: .nativeOwned,
                packageRelativePath: "mcp.json"),
        ]
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(portableDocument(
                artifacts: nativeArtifacts,
                definitions: [.init(artifactID: nativeChild, connection: .deviceBound(transport: .http))]))
        }
    }

    @Test func portableDefinitionsRejectDuplicatesAndSensitiveOrLocalURLs() throws {
        let identifier = ArtifactID()
        let duplicate = PortableMCPDefinitionRecord(
            artifactID: identifier, connection: .remoteHTTPS(url: "https://mcp.example.com"))
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(portableDocument(
                artifacts: [personalMCP(identifier)], definitions: [duplicate, duplicate]))
        }

        for url in ["https://user:token@mcp.example.com", "https://mcp.example.com/?token=secret", "https://localhost/mcp",
                    "https://localhost./mcp", "https://host.local/mcp", "https://192.168.1.10/mcp",
                    "https://10.1.2.3/mcp", "https://169.254.1.1/mcp", "https://[fd00::1]/mcp",
                    "https://[fe80::1]/mcp", "https://[::1]/mcp"] {
            #expect(throws: WorkspaceDomainValidationError.self) {
                _ = try WorkspaceDocumentCoding.seal(portableDocument(
                    artifacts: [personalMCP(identifier)],
                    definitions: [.init(artifactID: identifier, connection: .remoteHTTPS(url: url))]))
            }
        }
    }

    @Test func deviceBindingsRoundTripPreserveArgumentVectorsAndCanonicalize() throws {
        let remoteID = ArtifactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let commandID = ArtifactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let portable = try WorkspaceDocumentCoding.seal(portableDocument(
            artifacts: [personalMCP(remoteID), personalMCP(commandID)],
            definitions: [
                .init(artifactID: remoteID, connection: .remoteHTTPS(url: "https://mcp.example.com")),
                .init(artifactID: commandID, connection: .deviceBound(transport: .stdio)),
            ]))
        let state = DeviceWorkspaceState(
            workspaceID: portable.workspaceID,
            mcpBindings: [
                .init(
                    artifactID: commandID,
                    destination: .stdio(executable: "mcp-runner", arguments: ["--label", "two words"]),
                    credentialRequirementNames: ["SECOND_TOKEN", "FIRST_TOKEN"]),
                .init(artifactID: remoteID, credentialRequirementNames: ["REMOTE_TOKEN"]),
            ])

        let bytes = try WorkspaceDocumentCoding.encodeDeviceState(state)
        let decoded = try WorkspaceDocumentCoding.decodeDeviceState(bytes, against: portable)
        #expect(decoded.mcpBindings?.map(\.artifactID) == [remoteID, commandID])
        #expect(decoded.mcpBindings?.last?.destination == .stdio(executable: "mcp-runner", arguments: ["--label", "two words"]))
        #expect(decoded.mcpBindings?.last?.credentialRequirementNames == ["FIRST_TOKEN", "SECOND_TOKEN"])
    }

    @Test func deviceBindingsRejectOrphansOverridesUnsafeEndpointsAndInlineSecrets() throws {
        let remoteID = ArtifactID()
        let commandID = ArtifactID()
        let portable = try WorkspaceDocumentCoding.seal(portableDocument(
            artifacts: [personalMCP(remoteID), personalMCP(commandID)],
            definitions: [
                .init(artifactID: remoteID, connection: .remoteHTTPS(url: "https://mcp.example.com")),
                .init(artifactID: commandID, connection: .deviceBound(transport: .stdio)),
            ]))
        func invalid(_ bindings: [DeviceMCPDefinitionBinding]) {
            let state = DeviceWorkspaceState(workspaceID: portable.workspaceID, mcpBindings: bindings)
            #expect(throws: WorkspaceDomainValidationError.self) { try state.validateStructure(against: portable) }
        }

        invalid([.init(artifactID: ArtifactID(), destination: .stdio(executable: "runner", arguments: []))])
        invalid([.init(artifactID: remoteID, destination: .httpURL("https://mcp.example.com"))])
        invalid([.init(artifactID: commandID, destination: .httpURL("https://mcp.example.com"))])
        invalid([.init(artifactID: commandID, destination: .stdio(executable: "runner", arguments: ["--token", "secret"]))])
        invalid([.init(artifactID: commandID, destination: .stdio(executable: "runner", arguments: ["sk-abcdefghijklmnop1234"]))])
        invalid([.init(artifactID: remoteID, destination: .httpURL("https://user:token@mcp.example.com"))])
        invalid([.init(artifactID: remoteID), .init(artifactID: remoteID)])
        invalid([.init(artifactID: remoteID, credentialRequirementNames: ["API_TOKEN=secret"])])
        invalid([.init(artifactID: remoteID, workspaceRootPath: "relative/root")])
        var invalidPortable = portable
        invalidPortable.artifacts.removeAll { $0.identity.id == commandID }
        #expect(throws: WorkspaceDomainValidationError.self) {
            try DeviceWorkspaceState(workspaceID: portable.workspaceID, mcpBindings: [
                .init(artifactID: commandID, destination: .stdio(executable: "runner", arguments: []))
            ]).validateStructure(against: invalidPortable)
        }
    }

    @Test func schemaThreeWireRejectsUnknownMCPPayloadFields() throws {
        let identifier = ArtifactID()
        let document = try WorkspaceDocumentCoding.seal(portableDocument(
            artifacts: [personalMCP(identifier)],
            definitions: [.init(artifactID: identifier, connection: .remoteHTTPS(url: "https://mcp.example.com"))]))
        let text = String(decoding: try WorkspaceDocumentCoding.encode(document), as: UTF8.self)
        let mixed = text.replacingOccurrences(of: "\"kind\":\"remoteHTTPS\"", with: "\"kind\":\"remoteHTTPS\",\"transport\":\"stdio\"")
        #expect(mixed != text)
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceDocumentCoding.decode(Data(mixed.utf8))
        }
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID,
            mcpBindings: [.init(artifactID: identifier, authenticationRequirement: .oauth)])
        let deviceText = String(decoding: try WorkspaceDocumentCoding.encodeDeviceState(device), as: UTF8.self)
        let unsupported = deviceText.replacingOccurrences(of: "\"authenticationRequirement\":\"oauth\"",
            with: "\"authenticationRequirement\":\"oauth\",\"credentialValue\":\"hidden\"")
        #expect(unsupported != deviceText)
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceDocumentCoding.decodeDeviceState(Data(unsupported.utf8), against: document)
        }
    }

    @Test func deviceMCPBindingsDoNotChangePortableDigest() throws {
        let identifier = ArtifactID()
        let portable = try WorkspaceDocumentCoding.seal(portableDocument(
            artifacts: [personalMCP(identifier)],
            definitions: [.init(artifactID: identifier, connection: .deviceBound(transport: .stdio))]))
        let digest = portable.revision.documentDigest
        var device = DeviceWorkspaceState(workspaceID: portable.workspaceID, mcpBindings: [
            .init(artifactID: identifier, destination: .stdio(executable: "runner", arguments: ["--one"]))
        ])
        try device.validateStructure(against: portable)
        device.mcpBindings?[0] = .init(
            artifactID: identifier,
            destination: .stdio(executable: "other-runner", arguments: ["--two"]),
            credentialRequirementNames: ["LOCAL_TOKEN"])
        try device.validateStructure(against: portable)
        #expect(try WorkspaceDocumentCoding.digest(for: portable) == digest)
    }

    @Test func schemasOneAndTwoOmitMCPFieldsAndSchemaThreeCannotBeDownVersioned() throws {
        let writer = WorkspaceObjectID()
        let v1 = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            schemaVersion: 1, minimumReaderVersion: 1, minimumWriterVersion: 1,
            revision: .init(writerID: writer), configurationState: nil))
        let v2 = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            schemaVersion: 2, minimumReaderVersion: 2, minimumWriterVersion: 2,
            revision: .init(writerID: writer), configurationState: .init()))
        for document in [v1, v2] {
            let bytes = try WorkspaceDocumentCoding.encode(document)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("mcpDefinitions"))
            #expect(try WorkspaceDocumentCoding.decode(bytes) == document)
            #expect(try WorkspaceDocumentCoding.decode(bytes).mcpDefinitions == nil)
        }

        let v1Device = DeviceWorkspaceState(schemaVersion: 1, workspaceID: v1.workspaceID, configurationState: nil)
        let v2Device = DeviceWorkspaceState(schemaVersion: 2, workspaceID: v2.workspaceID, configurationState: .init())
        for state in [v1Device, v2Device] {
            let bytes = try WorkspaceDocumentCoding.encodeDeviceState(state)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("mcpBindings"))
            #expect(try WorkspaceDocumentCoding.decodeDeviceState(bytes) == state)
            #expect(try WorkspaceDocumentCoding.decodeDeviceState(bytes).mcpBindings == nil)
        }

        var downVersionedDocument = PortableWorkspaceDocument(revision: .init(writerID: writer))
        downVersionedDocument.schemaVersion = 2
        downVersionedDocument.minimumReaderVersion = 2
        downVersionedDocument.minimumWriterVersion = 2
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.seal(downVersionedDocument)
        }
        var downVersionedDevice = DeviceWorkspaceState(workspaceID: WorkspaceObjectID())
        downVersionedDevice.schemaVersion = 2
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.encodeDeviceState(downVersionedDevice)
        }
    }

    private func portableDocument(
        artifacts: [ArtifactRecord] = [],
        definitions: [PortableMCPDefinitionRecord] = []
    ) -> PortableWorkspaceDocument {
        PortableWorkspaceDocument(
            revision: .init(writerID: WorkspaceObjectID()),
            artifacts: artifacts,
            mcpDefinitions: definitions)
    }

    private func personalMCP(_ id: ArtifactID) -> ArtifactRecord {
        .init(identity: .init(id: id, kind: .mcpServer, displayName: "Personal MCP"), authority: .centralPersonal)
    }
}
