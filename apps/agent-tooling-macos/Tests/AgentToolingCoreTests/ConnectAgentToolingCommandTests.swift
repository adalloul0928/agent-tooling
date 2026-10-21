import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Recording Agent Tooling's own connection: one revision that holds the
/// connection, this Mac's binding of the helper's path and this Mac's apps;
/// a second Mac binding the same connection for itself; a hand registration
/// the first read tracked becoming the connection; and the helper paths no
/// app could keep, refused.
@Suite("Connect Agent Tooling")
struct ConnectAgentToolingCommandTests {
    static let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"

    @Test func theFirstMacRecordsTheConnectionItsBindingAndItsAppsInOneRevision() async throws {
        let mac = try Mac("juniper")
        defer { mac.remove() }
        let head = mac.head()

        let command = try ConnectAgentToolingCommand(expectedRevisionID: head, helperPath: Self.helper, apps: [.codex, .claude])
        let receipt = try await mac.service.connectAgentTooling(command)

        let snapshot = try #require(try mac.store.snapshot())
        #expect(receipt.previousRevisionID == head)
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        #expect(snapshot.document.revision.parentIDs == [head])
        let connection = try #require(AgentToolingConnection.ownConnection(in: snapshot.document))
        #expect(receipt.affectedArtifactIDs == [connection.identity.id])
        #expect(connection.identity.id == command.artifactID)
        #expect(connection.identity.displayName == "Agent Tooling")
        #expect(connection.declaredName == "agent-tooling")
        #expect(
            snapshot.document.mcpDefinitions == [.init(artifactID: connection.identity.id, connection: .deviceBound(transport: .stdio))])
        let binding = try #require(snapshot.device.mcpBindings?.first { $0.artifactID == connection.identity.id })
        #expect(binding.destination == .stdio(executable: Self.helper, arguments: []))
        #expect(binding.authenticationRequirement == .none)
        #expect(binding.credentialRequirementNames.isEmpty)
        // Its apps, on this Mac alone, for the person, by hand.
        #expect(
            Set(snapshot.document.assignments.map(\.destination)) == [
                .init(surface: .codexCLI, scope: .user, deviceIDs: [mac.store.deviceID]),
                .init(surface: .claudeCode, scope: .user, deviceIDs: [mac.store.deviceID]),
            ])
        #expect(snapshot.document.assignments.allSatisfy { $0.reason == .manual && $0.artifactID == connection.identity.id })
        // The path is this Mac's: it never enters the portable bytes.
        let portable = String(decoding: try WorkspaceDocumentCoding.encode(snapshot.document), as: UTF8.self)
        #expect(!portable.contains("Helpers/agent-tooling-mcp"))
    }

    @Test func aSecondMacBindsTheSameConnectionAndRecordsOnlyItsOwnApps() async throws {
        let juniper = try Mac("juniper")
        defer { juniper.remove() }
        _ = try await juniper.service.connectAgentTooling(
            try ConnectAgentToolingCommand(expectedRevisionID: juniper.head(), helperPath: Self.helper, apps: [.codex, .claude]))
        let shared = try #require(try juniper.store.snapshot()).document
        let cedar = try Mac("cedar", joining: shared)
        defer { cedar.remove() }
        let cedarHelper = "/Users/example/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"

        _ = try await cedar.service.connectAgentTooling(
            try ConnectAgentToolingCommand(expectedRevisionID: cedar.head(), helperPath: cedarHelper, apps: [.claude]))

        let snapshot = try #require(try cedar.store.snapshot())
        let connection = try #require(AgentToolingConnection.ownConnection(in: snapshot.document))
        #expect(snapshot.document.artifacts.count { $0.identity.kind == .mcpServer } == 1)
        #expect(connection.identity.id == AgentToolingConnection.ownConnection(in: shared)?.identity.id)
        #expect(snapshot.device.mcpBindings?.first?.destination == .stdio(executable: cedarHelper, arguments: []))
        let byDevice = Dictionary(grouping: snapshot.document.assignments) { $0.destination.deviceIDs ?? [] }
        #expect(
            byDevice[[juniper.store.deviceID]]?.map(\.destination.surface).sorted { $0.rawValue < $1.rawValue } == [.claudeCode, .codexCLI])
        #expect(byDevice[[cedar.store.deviceID]]?.map(\.destination.surface) == [.claudeCode])
    }

    /// Another Mac neither runs this Mac's path nor is asked to set up a
    /// connection it has no binding for: a contribution that names this Mac
    /// alone is not that Mac's at all.
    @Test func anotherMacsPlanLeavesThisMacsConnectionAlone() async throws {
        let juniper = try Mac("juniper")
        defer { juniper.remove() }
        _ = try await juniper.service.connectAgentTooling(
            try ConnectAgentToolingCommand(expectedRevisionID: juniper.head(), helperPath: Self.helper, apps: [.codex]))
        let document = try #require(try juniper.store.snapshot()).document
        let cedar = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let target = ResolvedAssignmentTarget(
            selector: .init(surface: .codexCLI, scope: .user, logicalProjectID: nil), physicalDestinationID: WorkspaceObjectID(),
            installedClientVersion: "0.164.0", adapterContractVersion: 1,
            componentContexts: [.init(component: .mcpServer, transport: "stdio")])

        let plan = WorkspaceDeploymentPlanner.plan(document: document, device: cedar, targets: [target])

        #expect(plan.items.isEmpty)
        #expect(plan.exclusions.isEmpty)
    }

    /// A registration somebody made by hand, which the first read tracked
    /// under this name, blocks recording the connection the paste path's way;
    /// this command makes that row the connection instead, keeping its
    /// identity.
    @Test func aTrackedRegistrationBecomesTheConnectionInPlace() async throws {
        let tracked = ArtifactRecord(
            identity: .init(id: ArtifactID(), kind: .mcpServer, displayName: "agent-tooling"), authority: .trackedOnly,
            declaredName: "agent-tooling")
        let mac = try Mac("tracked", artifacts: [tracked])
        defer { mac.remove() }
        let intake = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: mac.head(), displayName: AgentToolingConnection.displayName, stdioCommand: [Self.helper])
        await #expect(throws: ManagedMCPServerIntakeError.alreadyManaged("agent-tooling")) {
            _ = try await mac.service.intakeManagedMCPServer(intake)
        }

        _ = try await mac.service.connectAgentTooling(
            try ConnectAgentToolingCommand(expectedRevisionID: mac.head(), helperPath: Self.helper, apps: [.claude]))

        let snapshot = try #require(try mac.store.snapshot())
        let connection = try #require(AgentToolingConnection.ownConnection(in: snapshot.document))
        #expect(connection.identity.id == tracked.identity.id)
        #expect(connection.identity.displayName == "Agent Tooling")
        #expect(snapshot.document.artifacts.count { $0.identity.kind == .mcpServer } == 1)
        #expect(snapshot.document.tombstones.isEmpty)
        #expect(snapshot.device.mcpBindings?.first?.artifactID == tracked.identity.id)
    }

    /// Choosing again makes this Mac's apps exactly the new choice: what was
    /// dropped is withdrawn, what was added is added, another Mac's are
    /// untouched, and a copy that moved is bound at its new path.
    @Test func choosingAgainReconcilesThisMacsAppsAndRebindsAMovedCopy() async throws {
        let mac = try Mac("again")
        defer { mac.remove() }
        _ = try await mac.service.connectAgentTooling(
            try ConnectAgentToolingCommand(expectedRevisionID: mac.head(), helperPath: Self.helper, apps: [.codex, .claude]))
        let first = try #require(try mac.store.snapshot())
        let connection = try #require(AgentToolingConnection.ownConnection(in: first.document)).identity.id
        let otherMac = WorkspaceObjectID()
        let theirs = AssignmentContribution(
            artifactID: connection, destination: .init(surface: .geminiCLI, scope: .user, deviceIDs: [otherMac]), reason: .manual)
        _ = try await mac.service.applyAssignmentBatch(.init(expectedRevisionID: mac.head(), additions: [theirs]))
        let kept = try #require(first.document.assignments.first { $0.destination.surface == .claudeCode })
        let moved = "/Users/example/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"

        _ = try await mac.service.connectAgentTooling(
            try ConnectAgentToolingCommand(expectedRevisionID: mac.head(), helperPath: moved, apps: [.claude, .gemini]))

        let snapshot = try #require(try mac.store.snapshot())
        let mine = snapshot.document.assignments.filter { $0.destination.deviceIDs == [mac.store.deviceID] }
        #expect(Set(mine.map(\.destination.surface)) == [.claudeCode, .geminiCLI])
        #expect(mine.contains { $0.id == kept.id }, "an unchanged app keeps its contribution")
        #expect(snapshot.document.assignments.contains(theirs))
        #expect(snapshot.device.mcpBindings?.first?.destination == .stdio(executable: moved, arguments: []))
        #expect(snapshot.document.artifacts.count { $0.identity.kind == .mcpServer } == 1)
    }

    @Test func helperPathsNoAppCouldKeepAreRefused() {
        for path in [
            "/Volumes/Agent Tooling/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp",
            "/private/var/folders/xy/T/AppTranslocation/0B1C/d/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp",
            "/usr/local/bin/agent-tooling-mcp",
            "Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp",
            "/Applications/Agent Tooling.app/Contents/MacOS/AgentTooling",
            "/Applications/Agent Tooling/Contents/Helpers/agent-tooling-mcp",
            "/Applications/Agent\nTooling.app/Contents/Helpers/agent-tooling-mcp",
        ] {
            #expect(throws: ConnectAgentToolingError.self, "\(path)") {
                _ = try ConnectAgentToolingCommand(expectedRevisionID: WorkspaceObjectID(), helperPath: path, apps: [.codex])
            }
        }
        #expect(throws: Never.self) {
            _ = try ConnectAgentToolingCommand(
                expectedRevisionID: WorkspaceObjectID(),
                helperPath: "/Users/example/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp", apps: [])
        }
    }

    /// Another writer moved the head between reading it and committing (a
    /// device check recording itself, say): the same change is committed on
    /// the newer head, and replaying the command returns that first result.
    @Test func aStaleHeadIsCommittedOnTheNewerOneAndAReplayReturnsTheFirstReceipt() async throws {
        let mac = try Mac("stale")
        defer { mac.remove() }
        let command = try ConnectAgentToolingCommand(expectedRevisionID: mac.head(), helperPath: Self.helper, apps: [.codex])
        var other = MCPDraft()
        other.name = "Playwright"
        other.endpoint = "npx @playwright/mcp@latest"
        other.transport = .stdio
        _ = try await mac.service.intakeManagedMCPServer(try ManagedMCPServerIntakeCommand(expectedRevisionID: mac.head(), draft: other))
        let moved = mac.head()

        let receipt = try await mac.service.connectAgentTooling(command)
        let replay = try await mac.service.connectAgentTooling(command)

        #expect(receipt.previousRevisionID == moved)
        #expect(replay == receipt)
        #expect(mac.head() == receipt.committedRevisionID)
    }

    /// A preview is the library and this Mac as recording would leave them,
    /// worked out in memory: the same connection, binding and apps the
    /// commit then writes, and nothing written meanwhile.
    @Test func aPreviewIsWhatRecordingWouldLeaveAndWritesNothing() async throws {
        let mac = try Mac("juniper")
        defer { mac.remove() }
        let head = mac.head()
        let command = try ConnectAgentToolingCommand(expectedRevisionID: head, helperPath: Self.helper, apps: [.codex, .gemini])

        let preview = try command.preview(of: try #require(try mac.store.snapshot()), deviceID: mac.store.deviceID)

        #expect(mac.head() == head, "nothing was written")
        #expect(preview.connection == command.artifactID)
        _ = try await mac.service.connectAgentTooling(command)
        let recorded = try #require(try mac.store.snapshot())
        #expect(Set(preview.snapshot.document.assignments.map(\.destination)) == Set(recorded.document.assignments.map(\.destination)))
        #expect(preview.snapshot.document.mcpDefinitions == recorded.document.mcpDefinitions)
        #expect(preview.snapshot.device.mcpBindings == recorded.device.mcpBindings)

        // With no connection and no app wanted, there is nothing to preview.
        let empty = try Mac("cedar")
        defer { empty.remove() }
        let none = try ConnectAgentToolingCommand(expectedRevisionID: empty.head(), helperPath: Self.helper, apps: [])
        #expect(try none.preview(of: try #require(try empty.store.snapshot()), deviceID: empty.store.deviceID).connection == nil)
    }

    /// The argument vector goes to the binding exactly as given, a path with
    /// spaces as one argument, and nothing is asked to sign in.
    @Test func theArgvIntakeKeepsTheVectorAndAsksForNoSignIn() throws {
        let intake = try ManagedMCPServerIntakeCommand(
            expectedRevisionID: WorkspaceObjectID(), displayName: "Agent Tooling", stdioCommand: [Self.helper])
        #expect(intake.declaredName == "agent-tooling")
        #expect(intake.connection == .deviceBound(transport: .stdio))
        #expect(intake.destination == .stdio(executable: Self.helper, arguments: []))
        #expect(intake.authenticationRequirement == .none)
        #expect(intake.credentialRequirementNames.isEmpty)
        #expect(throws: MCPDefinitionValidationError.self) {
            _ = try ManagedMCPServerIntakeCommand(
                expectedRevisionID: WorkspaceObjectID(), displayName: "Agent Tooling", stdioCommand: [Self.helper, "--token", "abc"])
        }
    }

    // MARK: - A Mac with a library

    private struct Mac {
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init(_ name: String, joining shared: PortableWorkspaceDocument? = nil, artifacts: [ArtifactRecord] = []) throws {
            root = try TemporaryFolder("connect-agent-tooling-\(name)").url
            let writer = WorkspaceObjectID()
            // A second Mac starts from the same library, at a revision of its
            // own: the shared content, with no history this store lacks.
            var document = PortableWorkspaceDocument(
                workspaceID: shared?.workspaceID ?? WorkspaceObjectID(), revision: .init(writerID: writer),
                artifacts: shared?.artifacts ?? artifacts, assignments: shared?.assignments ?? [])
            if let definitions = shared?.mcpDefinitions { document.mcpDefinitions = definitions }
            document = try WorkspaceDocumentCoding.seal(document)
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store"), workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writer)
        }

        func head() -> WorkspaceObjectID {
            (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
