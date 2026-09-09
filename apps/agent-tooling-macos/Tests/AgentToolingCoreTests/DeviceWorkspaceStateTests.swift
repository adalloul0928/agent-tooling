import Foundation
import Testing

@testable import AgentToolingCore

struct DeviceWorkspaceStateTests {
    @Test func canonicalRoundTripKeepsPortableAndDeviceFactsSeparate() throws {
        let sourceID = object("00000000-0000-0000-0000-000000000101")
        let artifactID = artifact("00000000-0000-0000-0000-000000000102")
        let workspaceID = object("00000000-0000-0000-0000-000000000103")
        let portable = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            workspaceID: workspaceID,
            revision: revision(),
            artifacts: [ArtifactRecord(
                identity: ArtifactIdentity(id: artifactID, kind: .skill, displayName: "Draft"),
                authority: .attachedAuthoring(sourceRootID: sourceID), declaredName: "draft")],
            sources: [PortableSourceDescriptor(id: sourceID, role: .attachedAuthoring)]))
        let firstDevice = object("00000000-0000-0000-0000-000000000104")
        let secondDevice = object("00000000-0000-0000-0000-000000000105")
        let destinationID = object("00000000-0000-0000-0000-000000000106")
        let state = DeviceWorkspaceState(
            workspaceID: workspaceID, deviceID: firstDevice,
            sourceLocations: [SourceRootBinding(
                sourceRootID: sourceID, checkoutPath: "/tmp/agent-tooling-authoring",
                credentialReferenceID: "keychain:publisher")],
            destinations: [LinkedDestinationBinding(
                id: destinationID,
                selector: PortableDestination(
                    surface: .codexCLI, scope: .user, deviceIDs: [secondDevice, firstDevice]),
                resolvedPath: "/tmp/codex-skills", writePolicy: .reviewedReplacement)],
            capabilityEvidence: [TargetCapabilityEvidence(
                surface: .codexCLI, installedClientVersion: "1.2.3", adapterContractVersion: 1,
                component: .skill, scopes: [.user], support: .supported,
                observedAt: Date(timeIntervalSince1970: 1_788_890_400.1236))],
            deploymentBaselines: [DeploymentBaseline(
                artifactID: artifactID, destinationID: destinationID,
                deployedContent: ContentDigest(value: String(repeating: "a", count: 64)))])

        let encoded = try WorkspaceDocumentCoding.encodeDeviceState(state)
        let decoded = try WorkspaceDocumentCoding.decodeDeviceState(encoded, against: portable)
        #expect(decoded == state.canonicalized())
        #expect(decoded.destinations[0].selector.deviceIDs == [firstDevice, secondDevice])
        #expect(String(decoding: encoded, as: UTF8.self).contains(".124Z"))
    }

    @Test func nilAndEmptyDeviceScopesRemainDistinct() throws {
        let workspaceID = object("00000000-0000-0000-0000-000000000110")
        let all = LinkedDestinationBinding(
            id: object("00000000-0000-0000-0000-000000000111"),
            selector: PortableDestination(surface: .codexCLI, scope: .user, deviceIDs: nil),
            resolvedPath: "/tmp/all", writePolicy: .reviewedReplacement)
        let none = LinkedDestinationBinding(
            id: object("00000000-0000-0000-0000-000000000112"),
            selector: PortableDestination(surface: .codexCLI, scope: .user, deviceIDs: []),
            resolvedPath: "/tmp/none", writePolicy: .noClobberApplyOnce)
        let state = DeviceWorkspaceState(workspaceID: workspaceID, destinations: [none, all])

        let decoded = try WorkspaceDocumentCoding.decodeDeviceState(
            WorkspaceDocumentCoding.encodeDeviceState(state))
        #expect(decoded.destinations[0].selector.deviceIDs == nil)
        #expect(decoded.destinations[1].selector.deviceIDs == [])
    }

    @Test func deviceValidationRequiresPortableReferencesAndExplicitProjectContext() throws {
        let workspaceID = object("00000000-0000-0000-0000-000000000120")
        var state = DeviceWorkspaceState(
            workspaceID: workspaceID,
            destinations: [LinkedDestinationBinding(
                selector: PortableDestination(surface: .codexCLI, scope: .project),
                resolvedPath: "/tmp/project", writePolicy: .reviewedReplacement)])
        #expect(throws: WorkspaceDomainValidationError.self) { try state.validateStructure() }

        state.destinations[0].selector = PortableDestination(
            surface: .codexCLI, scope: .user,
            logicalProjectID: artifact("00000000-0000-0000-0000-000000000121"))
        #expect(throws: WorkspaceDomainValidationError.self) { try state.validateStructure() }

        state.destinations[0].selector = PortableDestination(surface: .codexCLI, scope: .user)
        state.destinations[0].resolvedPath = "relative/path"
        #expect(throws: WorkspaceDomainValidationError.self) { try state.validateStructure() }
    }

    @Test func decoderRejectsUnknownRootAndNestedDeviceFields() throws {
        let state = DeviceWorkspaceState(
            workspaceID: object("00000000-0000-0000-0000-000000000130"),
            destinations: [LinkedDestinationBinding(
                id: object("00000000-0000-0000-0000-000000000131"),
                selector: PortableDestination(surface: .codexCLI, scope: .user),
                resolvedPath: "/tmp/destination", writePolicy: .reviewedReplacement)])
        let text = String(decoding: try WorkspaceDocumentCoding.encodeDeviceState(state), as: UTF8.self)
        let rootUnknown = Data(("{\"addedRootField\":true," + text.dropFirst()).utf8)
        let nestedUnknown = Data(text.replacingOccurrences(
            of: "\"resolvedPath\":\"/tmp/destination\"",
            with: "\"addedNestedField\":true,\"resolvedPath\":\"/tmp/destination\"").utf8)
        #expect(rootUnknown != Data(text.utf8))
        #expect(nestedUnknown != Data(text.utf8))

        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.decodeDeviceState(rootUnknown)
        }
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.decodeDeviceState(nestedUnknown)
        }
    }

    private func revision() -> WorkspaceRevision {
        WorkspaceRevision(
            id: object("00000000-0000-0000-0000-000000000140"),
            writerID: object("00000000-0000-0000-0000-000000000141"),
            createdAt: Date(timeIntervalSince1970: 1_788_890_400))
    }

    private func artifact(_ value: String) -> ArtifactID { ArtifactID(UUID(uuidString: value)!) }
    private func object(_ value: String) -> WorkspaceObjectID { WorkspaceObjectID(UUID(uuidString: value)!) }
}
