import Foundation
import Testing

@testable import AgentToolingCore

struct NativeMCPPortableValidationTests {
    @Test func schemaFourRoundTripsAPathlessNativeMCPDeclaration() throws {
        let document = try WorkspaceDocumentCoding.seal(Self.document())
        let decoded = try WorkspaceDocumentCoding.decode(WorkspaceDocumentCoding.encode(document))

        // The pathless native declaration is admitted from schema 4 onward.
        #expect(document.schemaVersion >= 4)
        #expect(decoded == document.canonicalized())
        #expect(decoded.artifacts.first { $0.identity.kind == .mcpServer }?.packageRelativePath == nil)
    }

    @Test func historicalSchemasKeepRequiringAChildPath() throws {
        for version: UInt in 1...3 {
            var document = Self.document()
            document.schemaVersion = version
            document.minimumReaderVersion = version
            document.minimumWriterVersion = version
            document.configurationState = version == 1 ? nil : .init()
            document.mcpDefinitions = version < 3 ? nil : []
            #expect(throws: WorkspaceDomainValidationError.self) {
                try document.validateStructure()
            }
            // The existing path-based record remains valid and byte-stable.
            document.artifacts[1].packageRelativePath = "mcp/browser-tools"
            let sealed = try WorkspaceDocumentCoding.seal(document)
            let encoded = try WorkspaceDocumentCoding.encode(sealed)
            #expect(try WorkspaceDocumentCoding.encode(WorkspaceDocumentCoding.decode(encoded)) == encoded)
        }
    }

    @Test func onlyTheWholeNativePluginCanReceiveAnAssignment() throws {
        var document = Self.document()
        let destination = PortableDestination(surface: .codexCLI, scope: .user,
            deviceIDs: [document.revision.writerID])
        document.assignments = [.init(artifactID: document.artifacts[1].identity.id,
            destination: destination, reason: .manual)]
        #expect(throws: WorkspaceDomainValidationError.self) { try document.validateStructure() }
        document.assignments[0].artifactID = document.artifacts[0].identity.id
        _ = try WorkspaceDocumentCoding.seal(document)
    }

    @Test func pathlessExceptionIsLimitedToAnImmutableNamedNativeMCPChild() throws {
        let valid = Self.document()

        var unnamed = valid
        unnamed.artifacts[1].declaredName = nil
        #expect(throws: WorkspaceDomainValidationError.self) { try unnamed.validateStructure() }

        var emptyName = valid
        emptyName.artifacts[1].declaredName = ""
        #expect(throws: WorkspaceDomainValidationError.self) { try emptyName.validateStructure() }

        var materialized = valid
        materialized.artifacts[1].contentDigest = .init(value: String(repeating: "a", count: 64))
        #expect(throws: WorkspaceDomainValidationError.self) { try materialized.validateStructure() }

        var routed = valid
        routed.artifacts[1].nativeRoutes = [.init(client: .codex, externalPluginID: "child")]
        #expect(throws: WorkspaceDomainValidationError.self) { try routed.validateStructure() }

        var skill = valid
        skill.artifacts[1].identity.kind = .skill
        #expect(throws: WorkspaceDomainValidationError.self) { try skill.validateStructure() }

        var tracked = valid
        tracked.artifacts[1].authority = .trackedOnly
        #expect(throws: WorkspaceDomainValidationError.self) { try tracked.validateStructure() }

        var nonNativeParent = valid
        nonNativeParent.artifacts[0].identity.kind = .package
        #expect(throws: WorkspaceDomainValidationError.self) { try nonNativeParent.validateStructure() }
    }

    private static func document() -> PortableWorkspaceDocument {
        let parentID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000901")!)
        let childID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000902")!)
        let writerID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000903")!)
        let parent = ArtifactRecord(
            identity: .init(id: parentID, kind: .nativePlugin, displayName: "Browser"),
            authority: .nativeOwned,
            declaredName: "browser",
            nativeRoutes: [.init(client: .codex, externalPluginID: "browser")]
        )
        let child = ArtifactRecord(
            identity: .init(
                id: childID,
                kind: .mcpServer,
                displayName: "Browser tools",
                parentPackageID: parentID
            ),
            authority: .nativeOwned,
            declaredName: "browser-tools"
        )
        return PortableWorkspaceDocument(
            revision: .init(writerID: writerID),
            artifacts: [parent, child]
        )
    }
}
