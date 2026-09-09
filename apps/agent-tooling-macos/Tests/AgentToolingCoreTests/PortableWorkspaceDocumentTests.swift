import Foundation
import Testing

@testable import AgentToolingCore

struct PortableWorkspaceDocumentTests {
    @Test func minimalDocumentMatchesIndependentGoldenWireBytes() throws {
        let document = PortableWorkspaceDocument(
            schemaVersion: 1, minimumReaderVersion: 1, minimumWriterVersion: 1,
            workspaceID: object("00000000-0000-0000-0000-000000000001"),
            revision: WorkspaceRevision(
                id: object("00000000-0000-0000-0000-000000000002"),
                writerID: object("00000000-0000-0000-0000-000000000003"),
                createdAt: Date(timeIntervalSince1970: 0)), configurationState: nil)
        let sealed = try WorkspaceDocumentCoding.seal(document)
        let expectedDigest = "40159b8825eabaae0bd73b510f12dff22d2862089280f1e2f3248f1f6e10e5f9"
        let expected = """
        {"artifacts":[],"assignments":[],"logicalProjects":[],"minimumReaderVersion":1,"minimumWriterVersion":1,"presets":[],"revision":{"createdAt":"1970-01-01T00:00:00.000Z","documentDigest":{"algorithm":"sha256CanonicalJSONV1","value":"40159b8825eabaae0bd73b510f12dff22d2862089280f1e2f3248f1f6e10e5f9"},"id":"00000000-0000-0000-0000-000000000002","parentIDs":[],"writerID":"00000000-0000-0000-0000-000000000003"},"schemaVersion":1,"sources":[],"subscriptions":[],"tombstones":[],"workspaceID":"00000000-0000-0000-0000-000000000001"}
        """

        #expect(sealed.revision.documentDigest.value == expectedDigest)
        #expect(try WorkspaceDocumentCoding.encode(sealed) == Data(expected.utf8))
    }

    @Test func canonicalEncodingIsStableAndDigestExcludesItsOwnValue() throws {
        let fixture = try fixture()
        var reordered = fixture
        reordered.artifacts.reverse()
        reordered.artifacts[0].identity.aliases.reverse()
        reordered.revision.parentIDs.reverse()

        let first = try WorkspaceDocumentCoding.seal(fixture)
        let second = try WorkspaceDocumentCoding.seal(reordered)
        let firstData = try WorkspaceDocumentCoding.encode(first)
        let secondData = try WorkspaceDocumentCoding.encode(second)

        #expect(firstData == secondData)
        #expect(first.revision.documentDigest == second.revision.documentDigest)
        #expect(try WorkspaceDocumentCoding.decode(firstData) == first.canonicalized())
        let text = String(decoding: firstData, as: UTF8.self)
        #expect(text.contains("ABCDEF") == false)
        #expect(text.contains(".123Z"))

        var changed = first
        changed.artifacts[0].identity.displayName += " changed"
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try WorkspaceDocumentCoding.encode(changed)
        }
    }

    @Test func upstreamSubscriptionBelongsToOneRootAndChildrenInheritIt() throws {
        let valid = try fixture()
        try valid.validateStructure()

        let childID = try #require(valid.artifacts.first(where: { $0.identity.parentPackageID != nil })?.identity.id)
        var childOwned = valid
        childOwned.subscriptions[0].artifactID = childID
        #expect(throws: WorkspaceDomainValidationError.self) { try childOwned.validateStructure() }

        var wrongAuthority = valid
        let rootIndex = try #require(wrongAuthority.artifacts.firstIndex(where: { $0.identity.parentPackageID == nil }))
        wrongAuthority.artifacts[rootIndex].authority = .trackedOnly
        #expect(throws: WorkspaceDomainValidationError.self) { try wrongAuthority.validateStructure() }

        var wrongMaterializedDigest = valid
        wrongMaterializedDigest.artifacts[rootIndex].contentDigest = ContentDigest(value: String(repeating: "b", count: 64))
        #expect(throws: WorkspaceDomainValidationError.self) { try wrongMaterializedDigest.validateStructure() }

        var missingSourcePath = valid
        missingSourcePath.sources[0].packageRelativePaths = ["plugins/another"]
        #expect(throws: WorkspaceDomainValidationError.self) { try missingSourcePath.validateStructure() }
    }

    @Test func opposingEnablementConflictsRegardlessOfDeviceOrder() throws {
        let artifactID = artifact("00000000-0000-0000-0000-000000000010")
        let firstDevice = object("00000000-0000-0000-0000-000000000020")
        let secondDevice = object("00000000-0000-0000-0000-000000000021")
        let first = AssignmentContribution(
            id: object("00000000-0000-0000-0000-000000000030"), artifactID: artifactID,
            destination: PortableDestination(surface: .codexCLI, scope: .user, deviceIDs: [firstDevice, secondDevice]),
            reason: .manual, desiredEnabled: true)
        let second = AssignmentContribution(
            id: object("00000000-0000-0000-0000-000000000031"), artifactID: artifactID,
            destination: PortableDestination(surface: .codexCLI, scope: .user, deviceIDs: [secondDevice, firstDevice]),
            reason: .onboarding(configurationID: object("00000000-0000-0000-0000-000000000032")),
            desiredEnabled: false)
        let record = ArtifactRecord(
            identity: ArtifactIdentity(id: artifactID, kind: .skill, displayName: "Metadata only"),
            authority: .trackedOnly)
        let document = PortableWorkspaceDocument(
            revision: revision(), artifacts: [record], assignments: [first, second])

        #expect(throws: WorkspaceDomainValidationError.self) { try document.validateStructure() }
    }

    @Test func metadataOnlyAuthoritiesDoNotRequireInventedContent() throws {
        let tracked = ArtifactRecord(
            identity: ArtifactIdentity(id: artifact("00000000-0000-0000-0000-000000000040"), kind: .skill, displayName: "Observed"),
            authority: .trackedOnly)
        let native = ArtifactRecord(
            identity: ArtifactIdentity(
                id: artifact("00000000-0000-0000-0000-000000000041"), kind: .nativePlugin, displayName: "Native"),
            authority: .nativeOwned,
            nativeRoutes: [NativePackageRoute(client: .codex, externalPluginID: "documents@openai-bundled")])
        let personal = ArtifactRecord(
            identity: ArtifactIdentity(id: artifact("00000000-0000-0000-0000-000000000042"), kind: .skill, displayName: "Planned"),
            authority: .centralPersonal)
        let document = PortableWorkspaceDocument(revision: revision(), artifacts: [tracked, native, personal])

        let sealed = try WorkspaceDocumentCoding.seal(document)
        #expect(try WorkspaceDocumentCoding.decode(WorkspaceDocumentCoding.encode(sealed)) == sealed.canonicalized())
    }

    @Test func nativePackageKeepsOneIdentityGraphAcrossClientRoutes() throws {
        let rootID = artifact("00000000-0000-0000-0000-000000000050")
        let root = ArtifactRecord(
            identity: ArtifactIdentity(id: rootID, kind: .nativePlugin, displayName: "Shared native plugin"),
            authority: .nativeOwned,
            nativeRoutes: [
                NativePackageRoute(client: .codex, externalPluginID: "shared@publisher"),
                NativePackageRoute(client: .claude, externalPluginID: "shared-plugin"),
            ])
        let child = ArtifactRecord(
            identity: ArtifactIdentity(
                id: artifact("00000000-0000-0000-0000-000000000051"), kind: .skill,
                displayName: "Shared skill", parentPackageID: rootID),
            authority: .nativeOwned, packageRelativePath: "skills/shared")
        let document = PortableWorkspaceDocument(revision: revision(), artifacts: [child, root])
        let sealed = try WorkspaceDocumentCoding.seal(document)

        #expect(sealed.artifacts.count == 2)
        #expect(sealed.artifacts.first(where: { $0.identity.id == rootID })?.nativeRoutes.map(\.client) == [.claude, .codex])

        var duplicateClient = document
        duplicateClient.artifacts[1].nativeRoutes.append(
            NativePackageRoute(client: .codex, externalPluginID: "another-id"))
        #expect(throws: WorkspaceDomainValidationError.self) { try duplicateClient.validateStructure() }

        var routedChild = document
        routedChild.artifacts[0].nativeRoutes = [NativePackageRoute(client: .claude, externalPluginID: "child")]
        #expect(throws: WorkspaceDomainValidationError.self) { try routedChild.validateStructure() }
    }

    @Test func decoderRejectsNoncanonicalUUIDAndCredentialBearingLocator() throws {
        let sealed = try WorkspaceDocumentCoding.seal(try fixture())
        let encoded = try WorkspaceDocumentCoding.encode(sealed)
        let uppercase = Data(String(decoding: encoded, as: UTF8.self).replacingOccurrences(
            of: sealed.workspaceID.rawValue.uuidString.lowercased(), with: sealed.workspaceID.rawValue.uuidString).utf8)
        #expect(throws: DecodingError.self) { _ = try WorkspaceDocumentCoding.decode(uppercase) }

        var credentialed = try fixture()
        credentialed.sources[0].repositoryURL = "https://user:secret@example.com/repository"
        #expect(throws: WorkspaceDomainValidationError.self) { try credentialed.validateStructure() }
    }

    @Test func decoderRejectsUnknownRootAndNestedFieldsInsteadOfErasingThem() throws {
        let sealed = try WorkspaceDocumentCoding.seal(try fixture())
        let text = String(decoding: try WorkspaceDocumentCoding.encode(sealed), as: UTF8.self)
        let rootUnknown = Data(text.replacingOccurrences(
            of: "{\"artifacts\":", with: "{\"addedRootField\":true,\"artifacts\":").utf8)
        let nestedUnknown = Data(text.replacingOccurrences(
            of: "\"displayName\":\"Review\"", with: "\"addedNestedField\":true,\"displayName\":\"Review\"").utf8)

        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.decode(rootUnknown) }
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.decode(nestedUnknown) }
    }

    @Test func timestampsRoundOnceToCanonicalMilliseconds() throws {
        for (fraction, suffix) in [(0.1234, ".123Z"), (0.1236, ".124Z")] {
            var document = try fixture()
            document.revision.createdAt = Date(timeIntervalSince1970: 1_788_890_400 + fraction)
            let sealed = try WorkspaceDocumentCoding.seal(document)
            let encoded = try WorkspaceDocumentCoding.encode(sealed)
            #expect(String(decoding: encoded, as: UTF8.self).contains(suffix))
            #expect(try WorkspaceDocumentCoding.encode(WorkspaceDocumentCoding.decode(encoded)) == encoded)
        }
    }

    private func fixture() throws -> PortableWorkspaceDocument {
        let rootID = artifact("00000000-0000-0000-0000-000000000001")
        let childID = artifact("00000000-0000-0000-0000-000000000002")
        let sourceID = object("00000000-0000-0000-0000-000000000003")
        let subscriptionID = object("00000000-0000-0000-0000-000000000004")
        let digest = ContentDigest(value: String(repeating: "a", count: 64))
        let authority = ContentAuthority.centralUpstream(subscriptionID: subscriptionID)
        let root = ArtifactRecord(
            identity: ArtifactIdentity(
                id: rootID, kind: .package, displayName: "Review package",
                aliases: [
                    ExternalAlias(namespace: "legacy.skill", value: "z-review"),
                    ExternalAlias(namespace: "codex.plugin", value: "review@example"),
                ]),
            authority: authority, declaredName: "review-package", contentDigest: digest)
        let child = ArtifactRecord(
            identity: ArtifactIdentity(
                id: childID, kind: .skill, displayName: "Review", parentPackageID: rootID),
            authority: authority, declaredName: "review", packageRelativePath: "skills/review",
            contentDigest: ContentDigest(value: String(repeating: "c", count: 64)))
        let source = PortableSourceDescriptor(
            id: sourceID, role: .publisherRepository, repositoryURL: "https://github.com/example/review",
            requestedRef: "main", packageRelativePaths: ["plugins/review"])
        let lock = UpstreamLock(
            publisherID: "example", sourceRootID: sourceID, requestedRef: "main",
            approvedRevision: SourceRevision(kind: .gitCommitSHA1, value: String(repeating: "d", count: 40)),
            approvedContent: digest, packageRelativePath: "plugins/review")
        return PortableWorkspaceDocument(
            workspaceID: object("abcdefab-cdef-abcd-efab-cdefabcdefab"),
            revision: revision(), artifacts: [root, child], sources: [source],
            subscriptions: [UpstreamSubscription(id: subscriptionID, artifactID: rootID, sourceID: sourceID, lock: lock)])
    }

    private func revision() -> WorkspaceRevision {
        WorkspaceRevision(
            id: object("00000000-0000-0000-0000-000000000006"),
            parentIDs: [
                object("00000000-0000-0000-0000-000000000008"),
                object("00000000-0000-0000-0000-000000000007"),
            ],
            writerID: object("00000000-0000-0000-0000-000000000009"),
            createdAt: Date(timeIntervalSince1970: 1_788_890_400.123))
    }

    private func artifact(_ value: String) -> ArtifactID { ArtifactID(UUID(uuidString: value)!) }
    private func object(_ value: String) -> WorkspaceObjectID { WorkspaceObjectID(UUID(uuidString: value)!) }
}
