import Foundation
import Testing

@testable import AgentToolingCore

struct DeviceInventoryStateTests {
    @Test func capturesFieldRichLegacyRowsWithoutChangingTheirMeaning() throws {
        let fixture = try fieldRichFixture()
        let state = try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: fixture.bindings)

        #expect(state.records.count == 3)
        #expect(state.records.first { $0.legacy.domain == .skill }?.captured == .skill(fixture.snapshot.skills[0]))
        #expect(state.records.first { $0.legacy.domain == .mcpServer }?.captured == .mcpServer(fixture.snapshot.mcpServers[0]))
        #expect(state.records.first { $0.legacy.domain == .plugin }?.captured == .plugin(fixture.snapshot.plugins[0]))

        guard case .skill(let captured)? = state.records.first(where: { $0.legacy.domain == .skill })?.captured else {
            Issue.record("Expected captured skill metadata")
            return
        }
        #expect(captured.name == "source-name")
        #expect(captured.displayName == "Source Display Name")
        #expect(captured.summary == "Original summary")
        #expect(captured.triggers == ["Review this", "Check that"])
        #expect(captured.negativeTrigger == "Do not publish")
        #expect(captured.files == ["SKILL.md", "references/guide.md"])
        #expect(captured.clients == fixture.snapshot.skills[0].clients)
        #expect(captured.validationCount == 7)
        #expect(captured.authoringOrigin == .externalAdopted)
        #expect(captured.repositoryBinding == fixture.snapshot.skills[0].repositoryBinding)
    }

    @Test func preservesRepositoryUpdateEvidenceAndCanonicalizesOnlyItsDate() throws {
        let fixture = try fieldRichFixture()
        let state = try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: fixture.bindings)
        let canonical = state.canonicalized()
        guard case .skill(let before)? = state.records.first(where: { $0.legacy.domain == .skill })?.captured,
              case .skill(let after)? = canonical.records.first(where: { $0.legacy.domain == .skill })?.captured else {
            Issue.record("Expected captured skill metadata")
            return
        }

        #expect(after.repositoryBinding?.repositoryURL == before.repositoryBinding?.repositoryURL)
        #expect(after.repositoryBinding?.ref == before.repositoryBinding?.ref)
        #expect(after.repositoryBinding?.subdirectory == before.repositoryBinding?.subdirectory)
        #expect(after.repositoryBinding?.installedRevision == before.repositoryBinding?.installedRevision)
        #expect(after.repositoryBinding?.installedFingerprints == before.repositoryBinding?.installedFingerprints)
        #expect(after.repositoryBinding?.lastCheckedRevision == before.repositoryBinding?.lastCheckedRevision)
        #expect(after.repositoryBinding?.lastCheckedFingerprint == before.repositoryBinding?.lastCheckedFingerprint)
        #expect(after.repositoryBinding?.lastCheckError == before.repositoryBinding?.lastCheckError)
        #expect(after.repositoryBinding?.lastCheckedAt
            == before.repositoryBinding?.lastCheckedAt.map(WorkspaceDomainValidation.canonicalDate))
    }

    @Test func validatesAndRoundTripsAgainstLivePortableIdentities() throws {
        let fixture = try fieldRichFixture()
        let state = try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: fixture.bindings).canonicalized()
        let document = try portableDocument(bindings: fixture.bindings)

        try state.validate(against: document)
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID, inventoryState: state)
        let data = try WorkspaceDocumentCoding.encodeDeviceState(device)
        let decoded = try WorkspaceDocumentCoding.decodeDeviceState(data, against: document)
        #expect(decoded.inventoryState == state)
        try decoded.inventoryState?.validate(against: document)
    }

    @Test func initializerRejectsMissingBindingsAndInvalidCapturedRows() throws {
        let fixture = try fieldRichFixture()
        var missing = fixture.bindings
        missing.removeValue(forKey: key(.plugin, "plugin"))
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: missing)
        }

        var invalidSnapshot = fixture.snapshot
        invalidSnapshot.skills[0].clients.append(invalidSnapshot.skills[0].clients[0])
        #expect(throws: (any Error).self) {
            _ = try DeviceInventoryState(snapshot: invalidSnapshot, artifactBindings: fixture.bindings)
        }

        var nonfinite = fixture.snapshot
        nonfinite.skills[0].repositoryBinding?.lastCheckedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try DeviceInventoryState(snapshot: nonfinite, artifactBindings: fixture.bindings)
        }

        var credentialError = fixture.snapshot
        credentialError.skills[0].repositoryBinding?.lastCheckError = "access_token=secret-value"
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try DeviceInventoryState(snapshot: credentialError, artifactBindings: fixture.bindings)
        }
    }

    @Test func rejectsDuplicateLegacyAndArtifactIdentities() throws {
        let fixture = try fieldRichFixture()
        let skillRecord = try #require(
            try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: fixture.bindings)
                .records.first { $0.legacy.domain == .skill })
        let duplicateLegacy = DeviceInventoryState(records: [skillRecord, skillRecord])
        #expect(throws: WorkspaceDomainValidationError.self) { try duplicateLegacy.validate() }

        var other = try #require(
            try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: fixture.bindings)
                .records.first { $0.legacy.domain == .plugin })
        other.artifactID = skillRecord.artifactID
        let duplicateArtifact = DeviceInventoryState(records: [skillRecord, other])
        #expect(throws: WorkspaceDomainValidationError.self) { try duplicateArtifact.validate() }
    }

    @Test func rejectsPayloadKindDanglingArtifactAndReservedOnlyMapping() throws {
        let fixture = try fieldRichFixture()
        let state = try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: fixture.bindings)
        let skillRecord = try #require(state.records.first { $0.legacy.domain == .skill })
        let skillID = skillRecord.artifactID

        var mismatchedPayload = skillRecord
        mismatchedPayload.legacy = key(.mcpServer, "server")
        #expect(throws: WorkspaceDomainValidationError.self) {
            try DeviceInventoryState(records: [mismatchedPayload]).validate()
        }

        var missingArtifactDocument = try portableDocument(bindings: fixture.bindings)
        missingArtifactDocument.artifacts.removeAll { $0.identity.id == skillID }
        #expect(throws: WorkspaceDomainValidationError.self) {
            try DeviceInventoryState(records: [skillRecord]).validate(against: missingArtifactDocument)
        }

        var wrongKindDocument = try portableDocument(bindings: fixture.bindings)
        let index = try #require(wrongKindDocument.artifacts.firstIndex { $0.identity.id == skillID })
        wrongKindDocument.artifacts[index].identity.kind = .mcpServer
        #expect(throws: WorkspaceDomainValidationError.self) {
            try DeviceInventoryState(records: [skillRecord]).validate(against: wrongKindDocument)
        }

        var reservedOnlyDocument = try portableDocument(bindings: fixture.bindings)
        reservedOnlyDocument.configurationState?.identityMap.removeAll { $0.legacy == skillRecord.legacy }
        #expect(throws: WorkspaceDomainValidationError.self) {
            try DeviceInventoryState(records: [skillRecord]).validate(against: reservedOnlyDocument)
        }
    }

    @Test func canonicalizationIsDeterministicWithoutReorderingCapturedArrays() throws {
        let fixture = try fieldRichFixture()
        let original = try DeviceInventoryState(snapshot: fixture.snapshot, artifactBindings: fixture.bindings)
        let reversed = DeviceInventoryState(records: Array(original.records.reversed()))

        #expect(original.canonicalized() == reversed.canonicalized())
        guard case .skill(let skill)? = reversed.canonicalized().records
            .first(where: { $0.legacy.domain == .skill })?.captured else {
            Issue.record("Expected captured skill metadata")
            return
        }
        #expect(skill.triggers == ["Review this", "Check that"])
        #expect(skill.files == ["SKILL.md", "references/guide.md"])
        #expect(skill.clients.map(\.client) == [.codex, .claude])
    }

    private func fieldRichFixture() throws -> (
        snapshot: WorkspaceSnapshot,
        bindings: [LegacyReferenceKey: ArtifactID]
    ) {
        var repository = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/example/skills",
            ref: "main",
            subdirectory: "skills/source",
            installedFingerprints: ["/private/tmp/source": String(repeating: "a", count: 64)])
        repository.installedRevision = String(repeating: "b", count: 40)
        repository.lastCheckedRevision = String(repeating: "c", count: 40)
        repository.lastCheckedFingerprint = String(repeating: "d", count: 64)
        repository.lastCheckedAt = Date(timeIntervalSince1970: 1_788_900_000.1236)
        repository.lastCheckError = "Remote unavailable"
        let clients: [ClientState] = [
            .init(client: .codex, state: .healthy, detail: "Found", revision: "one", isInstalled: true),
            .init(client: .claude, state: .attention, detail: "Needs review", revision: nil, isInstalled: false),
        ]
        let skill = Skill(
            id: "source", name: "source-name", displayName: "Source Display Name",
            summary: "Original summary", bundle: "standalone", scope: "This Mac", owned: false,
            triggers: ["Review this", "Check that"], negativeTrigger: "Do not publish",
            files: ["SKILL.md", "references/guide.md"], clients: clients, validationCount: 7,
            authoringOrigin: .externalAdopted, repositoryBinding: repository)
        let server = MCPServer(
            id: "server", name: "Server", summary: "Observed server",
            endpoint: "https://mcp.example.com/service", transport: .http,
            authentication: "OAuth", scope: "This Mac", clients: clients,
            repairCommand: "agent-tooling repair server", secretNames: ["MCP_TOKEN"],
            definitionOrigin: .observed)
        let plugin = Plugin(
            id: "plugin", name: "Plugin", summary: "Native package", source: "Codex",
            scope: "This Mac", revision: "revision-one", skills: ["source"], profiles: ["profile"],
            clients: clients, installed: true)
        let snapshot = WorkspaceSnapshot(
            skills: [skill], mcpServers: [server], plugins: [plugin], activeProfileID: "")
        return (snapshot, [
            key(.skill, "source"): artifact("00000000-0000-0000-0000-000000000101"),
            key(.mcpServer, "server"): artifact("00000000-0000-0000-0000-000000000102"),
            key(.plugin, "plugin"): artifact("00000000-0000-0000-0000-000000000103"),
        ])
    }

    private func portableDocument(
        bindings: [LegacyReferenceKey: ArtifactID]
    ) throws -> PortableWorkspaceDocument {
        let artifacts = bindings.map { legacy, id in
            ArtifactRecord(
                identity: .init(id: id, kind: kind(legacy.domain), displayName: legacy.identifier),
                authority: .trackedOnly)
        }
        let identities = bindings.map { legacy, id in
            WorkspaceMigrationIdentityEntry(legacy: legacy, objectID: WorkspaceObjectID(id.rawValue))
        }
        return try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            revision: .init(writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)),
            artifacts: artifacts,
            configurationState: .init(identityMap: identities)))
    }

    private func kind(_ domain: LegacyReferenceDomain) -> ArtifactKind {
        switch domain {
        case .skill: .skill
        case .mcpServer: .mcpServer
        case .plugin: .package
        case .configuration, .collection, .catalogSource, .policy: .preset
        }
    }

    private func key(_ domain: LegacyReferenceDomain, _ identifier: String) -> LegacyReferenceKey {
        .init(domain: domain, identifier: identifier)
    }

    private func artifact(_ value: String) -> ArtifactID {
        ArtifactID(UUID(uuidString: value)!)
    }
}
