import Foundation
import Testing

@testable import AgentToolingCore

/// Recording how a connection is reached is a declaration and nothing else.
/// These check the three things that make it safe to keep: the portable half
/// says the same thing on every Mac, no secret reaches either half, and the
/// artifact, the definition and the binding are one transaction.
@Suite("Managed MCP server intake")
struct ManagedMCPServerIntakeCommandTests {

    // MARK: - The happy paths and the split

    @Test func aRemoteHTTPSDraftIsRecordedOnceForEveryMac() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let command = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: fixture.head(),
            draft: Self.draft(name: "Linear", endpoint: "https://mcp.linear.app/sse", transport: .http))
        let receipt = try await fixture.service.intakeManagedMCPServer(command)

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(receipt.affectedArtifactIDs == [command.artifactID])
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        let artifact = try #require(snapshot.document.artifacts.first)
        #expect(artifact.identity.kind == .mcpServer)
        #expect(artifact.authority == .centralPersonal)
        #expect(artifact.declaredName == "linear")
        #expect(artifact.identity.displayName == "Linear")
        #expect(artifact.identity.parentPackageID == nil)
        // A declaration holds no bytes and asks for nothing anywhere.
        #expect(artifact.contentDigest == nil)
        #expect(artifact.nativeRoutes.isEmpty)
        #expect(snapshot.document.assignments.isEmpty)
        #expect(snapshot.document.mcpDefinitions?.count == 1)
        #expect(
            snapshot.document.mcpDefinitions?.first?.connection
                == .remoteHTTPS(url: "https://mcp.linear.app/sse"))
        // A shared address needs no local setup, so the binding carries none.
        let binding = try #require(snapshot.device.mcpBindings?.first)
        #expect(binding.artifactID == command.artifactID)
        #expect(binding.destination == nil)
    }

    @Test func localAndStdioDraftsStayOnThisMac() async throws {
        for (endpoint, transport, expected) in [
            ("http://localhost:8080/mcp", MCPTransport.http, DeviceMCPDestination.httpURL("http://localhost:8080/mcp")),
            ("http://127.0.0.1:8080/mcp", .http, .httpURL("http://127.0.0.1:8080/mcp")),
            ("https://desktop.local/mcp", .http, .httpURL("https://desktop.local/mcp")),
            ("https://intranet/mcp", .http, .httpURL("https://intranet/mcp")),
            ("http://mcp.example.com/rpc", .http, .httpURL("http://mcp.example.com/rpc")),
            ("mcp-runner --stdio", .stdio, .stdio(executable: "mcp-runner", arguments: ["--stdio"])),
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }

            let command = try ManagedMCPServerIntakeCommand(
                expectedRevisionID: fixture.head(),
                draft: Self.draft(name: "local", endpoint: endpoint, transport: transport))
            _ = try await fixture.service.intakeManagedMCPServer(command)

            let snapshot = try #require(try fixture.store.snapshot())
            #expect(snapshot.document.mcpDefinitions?.first?.connection == .deviceBound(transport: transport))
            #expect(snapshot.device.mcpBindings?.first?.destination == expected)
            // The address a device resolves is never portable bytes.
            let portable = try WorkspaceDocumentCoding.encode(snapshot.document)
            #expect(!String(decoding: portable, as: UTF8.self).contains(endpoint))
        }
    }

    @Test func aStdioArgumentContainingASpaceSurvivesIntake() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let typed = "mcp-runner --label 'two words' --root /Users/me/My Projects"

        let command = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: fixture.head(),
            draft: Self.draft(name: "runner", endpoint: typed, transport: .stdio))
        _ = try await fixture.service.intakeManagedMCPServer(command)

        let snapshot = try #require(try fixture.store.snapshot())
        let destination = try #require(snapshot.device.mcpBindings?.first?.destination)
        guard case .stdio(let executable, let arguments) = destination else {
            Issue.record("a stdio draft did not produce a stdio destination")
            return
        }
        #expect(executable == "mcp-runner")
        #expect(arguments == ["--label", "two words", "--root", "/Users/me/My", "Projects"])
        // What was stored is exactly what the parser reads back out of the
        // quoted line the library shows, so a space never becomes two arguments.
        let shown = PastedDefinitionParser.shellQuoted([executable] + arguments)
        #expect(try MCPDefinitionValidator.parseCommandLine(shown) == [executable] + arguments)
    }

    @Test func aWorkspaceScopedConnectionWithNoProjectFolderIsStillRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var draft = Self.draft(name: "scoped", endpoint: "https://mcp.example.com/rpc", transport: .http)
        draft.scope = .workspace

        let command = try ManagedMCPServerIntakeCommand(expectedRevisionID: fixture.head(), draft: draft)
        _ = try await fixture.service.intakeManagedMCPServer(command)

        let snapshot = try #require(try fixture.store.snapshot())
        // The missing folder is reported at Install time, where it can be
        // fixed. Refusing here would lose the definition over a device fact.
        #expect(snapshot.device.mcpBindings?.first?.workspaceRootPath == nil)
        #expect(snapshot.document.mcpDefinitions?.count == 1)
    }

    @Test func aProjectFolderIsRecordedOnThisMacOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var draft = Self.draft(name: "scoped", endpoint: "https://mcp.example.com/rpc", transport: .http)
        draft.scope = .project
        draft.projectRoot = fixture.root.path

        let command = try ManagedMCPServerIntakeCommand(expectedRevisionID: fixture.head(), draft: draft)
        _ = try await fixture.service.intakeManagedMCPServer(command)

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.device.mcpBindings?.first?.workspaceRootPath == fixture.root.path)
        let portable = try WorkspaceDocumentCoding.encode(snapshot.document)
        #expect(!String(decoding: portable, as: UTF8.self).contains(fixture.root.path))
    }

    // MARK: - Secrets

    @Test func aDraftCarryingACredentialIsRefusedWithTheValidatorsWords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for (endpoint, transport) in [
            ("https://user:token@mcp.example.com/rpc", MCPTransport.http),
            ("https://mcp.example.com/rpc?token=abcdef", .http),
            ("mcp-runner --api-key abcdef123456", .stdio),
            ("mcp-runner --header 'Authorization: Bearer abcdef'", .stdio),
            // Split so a secret scanner does not read this rejection fixture as a
            // leak; the command sees the joined string.
            ("mcp-runner ACCESS_TOKEN=" + "abcdef123456", .stdio),
        ] {
            #expect(throws: MCPDefinitionValidationError.self) {
                _ = try ManagedMCPServerIntakeCommand(
                    expectedRevisionID: fixture.head(),
                    draft: Self.draft(name: "leaky", endpoint: endpoint, transport: transport))
            }
        }
        #expect(try fixture.store.snapshot()?.document.artifacts.isEmpty == true)
    }

    @Test func aURLShapedLikeAKeyIsRefusedRatherThanQuietlyMadeDeviceBound() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // Nothing about this becomes portable, so the tempting fallback is to
        // record it as this Mac's own address. That would store the key.
        let refusal = #expect(throws: MCPDefinitionValidationError.self) {
            _ = try ManagedMCPServerIntakeCommand(
                expectedRevisionID: fixture.head(),
                draft: Self.draft(
                    name: "leaky", endpoint: "https://mcp.example.com/sk-abcdefghijklmnop", transport: .http))
        }
        #expect(refusal == .sensitiveHTTPURL)
    }

    @Test func credentialNamesAreRecordedAndTheirValuesAreNowhere() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pasted = """
            claude mcp add tenant --transport http --url https://mcp.example.com/rpc \
            -e API_KEY=super-secret-value -e SECOND_NAME=another-secret -H X-Tenant=acme-secret
            """
        guard case .mcp(let result) = try PastedDefinitionParser.parse(pasted),
            let server = result.servers.first
        else {
            Issue.record("the paste did not read as an MCP server")
            return
        }
        let names = server.secretNames
        #expect(names == ["API_KEY", "SECOND_NAME", "X-Tenant"])

        let command = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: fixture.head(), draft: server.draft, credentialRequirementNames: names)
        _ = try await fixture.service.intakeManagedMCPServer(command)

        let snapshot = try #require(try fixture.store.snapshot())
        let binding = try #require(snapshot.device.mcpBindings?.first)
        #expect(binding.credentialRequirementNames == ["API_KEY", "SECOND_NAME", "X-Tenant"])
        let portable = String(decoding: try WorkspaceDocumentCoding.encode(snapshot.document), as: UTF8.self)
        let device = String(decoding: try WorkspaceDocumentCoding.encodeDeviceState(snapshot.device), as: UTF8.self)
        for secret in ["super-secret-value", "another-secret", "acme-secret"] {
            #expect(!portable.contains(secret))
            #expect(!device.contains(secret))
        }
        #expect(!portable.contains("API_KEY"))
        #expect(device.contains("API_KEY"))
    }

    @Test func aCredentialNameThatReadsAsAValueIsRefusedByName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for name in ["API_KEY=abcdef", "1TOKEN", "my token", "TOKEN: abcdef"] {
            let refusal = #expect(throws: ManagedMCPServerIntakeError.self) {
                _ = try ManagedMCPServerIntakeCommand(
                    expectedRevisionID: fixture.head(),
                    draft: Self.draft(name: "named", endpoint: "https://mcp.example.com/rpc", transport: .http),
                    credentialRequirementNames: [name])
            }
            #expect(refusal == .invalidCredentialName(name))
            #expect(refusal?.errorDescription?.contains(name) == true)
        }
    }

    @Test func aPasteThatDroppedNamesAndChoseNothingElseAsksForAnEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var draft = Self.draft(name: "runner", endpoint: "mcp-runner --stdio", transport: .stdio)
        draft.authentication = "None"

        let withNames = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: fixture.head(), draft: draft, credentialRequirementNames: ["GITHUB_PAT"])
        let without = try ManagedMCPServerIntakeCommand(expectedRevisionID: fixture.head(), draft: draft)

        #expect(withNames.authenticationRequirement == .environment)
        #expect(without.authenticationRequirement == .none)
        draft.authentication = "Doppler"
        #expect(
            try ManagedMCPServerIntakeCommand(expectedRevisionID: fixture.head(), draft: draft)
                .authenticationRequirement == .doppler)
        draft.authentication = "API key"
        #expect(
            try ManagedMCPServerIntakeCommand(expectedRevisionID: fixture.head(), draft: draft)
                .authenticationRequirement == .apiKey)
        draft.authentication = "OAuth"
        #expect(
            try ManagedMCPServerIntakeCommand(expectedRevisionID: fixture.head(), draft: draft)
                .authenticationRequirement == .oauth)
    }

    // MARK: - Refusals

    @Test func aSecondConnectionWithTheSameDeclaredNameIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.intakeManagedMCPServer(
            .init(
                expectedRevisionID: fixture.head(),
                draft: Self.draft(name: "Linear", endpoint: "https://mcp.linear.app/sse", transport: .http)))

        let refusal = await #expect(throws: ManagedMCPServerIntakeError.self) {
            _ = try await fixture.service.intakeManagedMCPServer(
                .init(
                    expectedRevisionID: fixture.head(),
                    draft: Self.draft(name: "linear", endpoint: "https://other.example.com/sse", transport: .http)))
        }
        #expect(refusal == .alreadyManaged("linear"))
        #expect(
            refusal?.errorDescription
                == "A connection called linear is already in your library. Open it to change how it is reached.")
        #expect(try fixture.store.snapshot()?.document.artifacts.count == 1)
    }

    @Test func aNameThisWorkspaceCannotRecordIsRefusedRatherThanRewritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let refusal = #expect(throws: ManagedMCPServerIntakeError.self) {
            _ = try ManagedMCPServerIntakeCommand(
                expectedRevisionID: fixture.head(),
                draft: Self.draft(name: "../escape", endpoint: "https://mcp.example.com", transport: .http))
        }
        #expect(refusal == .invalidConnectionName("../escape"))
    }

    @Test func anIdentityAlreadyUsedOrPreviouslyRemovedIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let taken = ArtifactID()
        _ = try await fixture.service.intakeManagedMCPServer(
            .init(
                expectedRevisionID: fixture.head(), artifactID: taken,
                draft: Self.draft(name: "first", endpoint: "https://mcp.example.com/one", transport: .http)))

        let collision = await #expect(throws: ManagedMCPServerIntakeError.self) {
            _ = try await fixture.service.intakeManagedMCPServer(
                .init(
                    expectedRevisionID: fixture.head(), artifactID: taken,
                    draft: Self.draft(name: "second", endpoint: "https://mcp.example.com/two", transport: .http)))
        }
        #expect(collision == .identityCollision)

        let buried = ArtifactID()
        _ = try fixture.store.commitMetadata(
            expectedRevisionID: fixture.head(), idempotencyKey: WorkspaceObjectID(),
            inputDigest: String(repeating: "b", count: 64), writerID: fixture.writerID
        ) { document in
            document.tombstones.append(.init(artifactID: buried, deletedInRevisionID: document.revision.id))
            return []
        }

        let removed = await #expect(throws: ManagedMCPServerIntakeError.self) {
            _ = try await fixture.service.intakeManagedMCPServer(
                .init(
                    expectedRevisionID: fixture.head(), artifactID: buried,
                    draft: Self.draft(name: "third", endpoint: "https://mcp.example.com/three", transport: .http)))
        }
        #expect(removed == .previouslyRemoved)
        #expect(
            removed?.errorDescription
                == "You removed a connection with this identity before. Add it back from the library rather than from a paste.")
    }

    @Test func aStaleExpectedRevisionIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = fixture.head()
        _ = try await fixture.service.intakeManagedMCPServer(
            .init(
                expectedRevisionID: stale,
                draft: Self.draft(name: "first", endpoint: "https://mcp.example.com/one", transport: .http)))

        await #expect(throws: WorkspaceRevisionStoreError.self) {
            _ = try await fixture.service.intakeManagedMCPServer(
                .init(
                    expectedRevisionID: stale,
                    draft: Self.draft(name: "second", endpoint: "https://mcp.example.com/two", transport: .http)))
        }
    }

    // MARK: - Replay and atomicity

    @Test func theSameCommandReplayedReturnsItsOriginalReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: fixture.head(),
            draft: Self.draft(name: "Linear", endpoint: "https://mcp.linear.app/sse", transport: .http))

        let first = try await fixture.service.intakeManagedMCPServer(command)
        let second = try await fixture.service.intakeManagedMCPServer(command)

        #expect(first == second)
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.artifacts.count == 1)
        #expect(snapshot.document.mcpDefinitions?.count == 1)
        #expect(snapshot.device.mcpBindings?.count == 1)
    }

    @Test func theArtifactAndItsDefinitionCannotLandSeparately() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identifier = ArtifactID()

        // The artifact alone is not a representable document: a standalone
        // personal connection without a definition has no address at all.
        #expect(throws: (any Error).self) {
            _ = try fixture.store.commitMetadata(
                expectedRevisionID: fixture.head(), idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "c", count: 64), writerID: fixture.writerID
            ) { document in
                document.artifacts.append(
                    .init(
                        identity: .init(id: identifier, kind: .mcpServer, displayName: "Half"),
                        authority: .centralPersonal, declaredName: "half"))
                return [identifier]
            }
        }
        #expect(try fixture.store.snapshot()?.document.artifacts.isEmpty == true)
    }

    @Test func aFailureInThisMacsHalfLeavesNeitherHalfBehind() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: fixture.head(),
            draft: Self.draft(name: "Linear", endpoint: "https://mcp.linear.app/sse", transport: .http))
        let before = try #require(try fixture.store.snapshot()).document.revision.id

        struct DeviceFailure: Error {}
        #expect(throws: DeviceFailure.self) {
            _ = try fixture.store.commitMetadata(
                expectedRevisionID: command.expectedRevisionID, idempotencyKey: command.idempotencyKey,
                inputDigest: command.inputDigest(), writerID: fixture.writerID,
                deviceMutation: { _ in throw DeviceFailure() },
                mutation: { try command.apply(to: &$0) })
        }

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.revision.id == before)
        #expect(snapshot.document.artifacts.isEmpty)
        #expect(snapshot.document.mcpDefinitions?.isEmpty == true)
        #expect(snapshot.device.mcpBindings?.isEmpty == true)
    }

    // MARK: - What the screens read back

    @Test func aRecordedConnectionResolvesInTheTestConsole() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.intakeManagedMCPServer(
            .init(
                expectedRevisionID: fixture.head(),
                draft: Self.draft(name: "Linear", endpoint: "https://mcp.linear.app/sse", transport: .http)))

        let state = try WorkspaceLibraryState(snapshot: try #require(try fixture.store.snapshot()))
        let projected = try #require(VersionedInventoryProjection.inventory(state.library).mcpServers.first)

        #expect(projected.endpoint == "https://mcp.linear.app/sse")
        #expect(projected.isManagedDefinition)
        #expect(projected.authentication == "OAuth")
        // Before the definition existed the console refused every projected
        // server with a message about a malformed endpoint.
        let target = try MCPTestConnectionPolicy.resolve(server: projected)
        #expect(target == .http(url: try #require(URL(string: "https://mcp.linear.app/sse"))))
        // The declaration says nothing about the connection being live.
        #expect(projected.clients.allSatisfy { $0.isInstalled != true })
    }

    // MARK: - Sync

    @Test func anotherMacReadsTheDocumentWithNoBindingOfItsOwn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.intakeManagedMCPServer(
            .init(
                expectedRevisionID: fixture.head(),
                draft: Self.draft(name: "Linear", endpoint: "https://mcp.linear.app/sse", transport: .http)))
        let document = try #require(try fixture.store.snapshot()).document

        // Device state never syncs, so the other Mac opens this document with
        // an empty one. That must read, not fail.
        let elsewhere = DeviceWorkspaceState(workspaceID: document.workspaceID)
        try elsewhere.validateStructure(against: document)
        let bytes = try WorkspaceDocumentCoding.encode(document)
        #expect(try WorkspaceDocumentCoding.decode(bytes) == document)
    }

    @Test func aSyncedWorkspaceWithNoConnectionsIsUnchangedByThisPacket() throws {
        let writerID = WorkspaceObjectID()
        let plain = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [
                    .init(
                        identity: .init(kind: .skill, displayName: "Standalone"),
                        authority: .centralPersonal, declaredName: "standalone")
                ]))

        let bytes = try WorkspaceDocumentCoding.encode(plain)
        #expect(try WorkspaceDocumentCoding.decode(bytes) == plain)
        #expect(plain.mcpDefinitions?.isEmpty == true)

        let merged = WorkspaceMergeEngine.merge(
            base: plain, local: plain, remote: plain, writerID: writerID)
        #expect(merged.conflicts.isEmpty)
        #expect(merged.document?.artifacts.map(\.identity.id) == plain.artifacts.map(\.identity.id))
        #expect(merged.document?.mcpDefinitions?.isEmpty == true)
    }

    @Test func twoMacsAddingDifferentConnectionsCombineAndOneEditedDefinitionConflicts() throws {
        let writerID = WorkspaceObjectID()
        let shared = ArtifactID()
        let base = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [Self.connection(shared, name: "shared")],
                mcpDefinitions: [.init(artifactID: shared, connection: .remoteHTTPS(url: "https://one.example.com/rpc"))]))

        let mine = ArtifactID()
        var local = base
        local.artifacts.append(Self.connection(mine, name: "mine"))
        local.mcpDefinitions?.append(.init(artifactID: mine, connection: .deviceBound(transport: .stdio)))
        local.revision = .init(parentIDs: [base.revision.id], writerID: writerID)
        local = try WorkspaceDocumentCoding.seal(local)

        let theirs = ArtifactID()
        var remote = base
        remote.artifacts.append(Self.connection(theirs, name: "theirs"))
        remote.mcpDefinitions?.append(.init(artifactID: theirs, connection: .deviceBound(transport: .http)))
        remote.revision = .init(parentIDs: [base.revision.id], writerID: writerID)
        remote = try WorkspaceDocumentCoding.seal(remote)

        let combined = WorkspaceMergeEngine.merge(base: base, local: local, remote: remote, writerID: writerID)
        #expect(combined.conflicts.isEmpty)
        #expect(Set(combined.document?.mcpDefinitions?.map(\.artifactID) ?? []) == [shared, mine, theirs])

        // The same connection re-pointed on both Macs is a real disagreement.
        var mineRepointed = base
        mineRepointed.mcpDefinitions = [
            .init(artifactID: shared, connection: .remoteHTTPS(url: "https://three.example.com/rpc"))
        ]
        mineRepointed.revision = .init(parentIDs: [base.revision.id], writerID: writerID)
        mineRepointed = try WorkspaceDocumentCoding.seal(mineRepointed)
        var theirsRepointed = base
        theirsRepointed.mcpDefinitions = [
            .init(artifactID: shared, connection: .remoteHTTPS(url: "https://two.example.com/rpc"))
        ]
        theirsRepointed.revision = .init(parentIDs: [base.revision.id], writerID: writerID)
        theirsRepointed = try WorkspaceDocumentCoding.seal(theirsRepointed)
        let contested = WorkspaceMergeEngine.merge(
            base: base, local: mineRepointed, remote: theirsRepointed, writerID: writerID)
        #expect(contested.conflicts.map(\.kind) == [.artifactField])
        #expect(contested.conflicts.first?.detail == "Both Macs changed this connection's shared definition.")
    }

    @Test func twoMacsAddingTheSameConnectionKeepBothRowsRatherThanRefusingTheMerge() throws {
        let writerID = WorkspaceObjectID()
        let base = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID)))

        var documents: [PortableWorkspaceDocument] = []
        for _ in 0..<2 {
            let identifier = ArtifactID()
            var side = base
            side.artifacts.append(Self.connection(identifier, name: "linear"))
            side.mcpDefinitions?.append(
                .init(artifactID: identifier, connection: .remoteHTTPS(url: "https://mcp.linear.app/sse")))
            side.revision = .init(parentIDs: [base.revision.id], writerID: writerID)
            documents.append(try WorkspaceDocumentCoding.seal(side))
        }

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: documents[0], remote: documents[1], writerID: writerID)

        // Two rows is recoverable and visible. A document-wide name-uniqueness
        // rule would turn an ordinary concurrent action into a whole-merge
        // refusal nobody can act on.
        #expect(merged.conflicts.isEmpty)
        #expect(merged.document?.artifacts.count == 2)
        #expect(merged.document?.mcpDefinitions?.count == 2)
    }

    // MARK: - Fixtures

    private static func draft(name: String, endpoint: String, transport: MCPTransport) -> MCPDraft {
        var draft = MCPDraft()
        draft.name = name
        draft.endpoint = endpoint
        draft.transport = transport
        return draft
    }

    private static func connection(_ identifier: ArtifactID, name: String) -> ArtifactRecord {
        .init(
            identity: .init(id: identifier, kind: .mcpServer, displayName: name),
            authority: .centralPersonal, declaredName: name)
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let writerID: WorkspaceObjectID

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "managed-mcp-intake-\(UUID())")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID)))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func head() -> WorkspaceObjectID {
            (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
