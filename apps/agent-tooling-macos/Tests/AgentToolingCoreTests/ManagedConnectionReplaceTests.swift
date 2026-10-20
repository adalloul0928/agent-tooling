import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Replacing a registration an app already holds (D30): the command plan
/// carries the removal that must run first (`preArguments`), Kiro CLI's add
/// replaces with `--force` instead, the operations builder runs both commands
/// from that one value as one reviewed step, and the plan names what the old
/// registration started.
@Suite("Managed connection replace")
struct ManagedConnectionReplaceTests {
    static let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"

    @Test func eachAppRemovesTheOldRegistrationFirstButKiroForcesItsAdd() {
        let name = AgentToolingConnection.declaredName
        #expect(
            WorkspaceManagedMCPCommandPlanning.removalBeforeAdd(serverID: name, client: .claude, scope: .user)
                == ["mcp", "remove", "--scope", "user", name])
        #expect(
            WorkspaceManagedMCPCommandPlanning.removalBeforeAdd(serverID: name, client: .codex, scope: .user)
                == ["mcp", "remove", name])
        #expect(
            WorkspaceManagedMCPCommandPlanning.removalBeforeAdd(serverID: name, client: .gemini, scope: .user)
                == ["mcp", "remove", "--scope", "user", name])
        #expect(WorkspaceManagedMCPCommandPlanning.removalBeforeAdd(serverID: name, client: .kiro, scope: .user) == nil)
        let kiro = MCPClientCommand.addArguments(
            serverID: name, transport: .stdio, destination: .init(endpoint: "", command: [Self.helper]), client: .kiro,
            scope: .user)
        #expect(kiro.last == "--force")
    }

    /// Every removal a replacement runs is one the executor's policy admits.
    @Test func thePolicyAdmitsEveryRemoval() throws {
        let policy = OperationCommandPolicy(
            libraryURL: URL(filePath: "/tmp/library"), gitBackupRoot: URL(filePath: "/tmp/backup"),
            homeURL: URL(filePath: "/tmp/home"))
        for client in [ClientKind.claude, .codex, .gemini] {
            let removal = try #require(
                WorkspaceManagedMCPCommandPlanning.removalBeforeAdd(
                    serverID: AgentToolingConnection.declaredName, client: client, scope: .user))
            try policy.validate(executable: MCPClientCommand.executable(for: client), arguments: removal)
        }
    }

    @Test func aReplacingPlanCarriesItsRemovalAndTheOldCommand() throws {
        let replacing = try Self.plan(replacing: true, replacedCommand: "/Users/me/Downloads/agent-tooling-mcp")
        #expect(replacing.preArguments == ["mcp", "remove", "--scope", "user", AgentToolingConnection.declaredName])
        #expect(replacing.replacedCommand == "/Users/me/Downloads/agent-tooling-mcp")
        #expect(replacing.arguments.prefix(2) == ["mcp", "add"])

        let adding = try Self.plan(replacing: false, replacedCommand: "/Users/me/Downloads/agent-tooling-mcp")
        #expect(adding.preArguments == nil)
        #expect(adding.replacedCommand == nil)
        #expect(adding.arguments == replacing.arguments)
    }

    /// The review lists both commands and the builder runs both: the removal,
    /// then the add, one reviewed step, in an operation of its own, so a
    /// failed removal stops only its own add. The app's other connections
    /// run in operations around it, in the reviewed order.
    @Test func theRemovalRunsBeforeTheAddAsOneReviewedStep() throws {
        let replacing = try Self.plan(replacing: true, replacedCommand: nil)
        func another(_ name: String) -> WorkspaceManagedMCPCommandPlan {
            WorkspaceManagedMCPCommandPlan(
                artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID(), surface: .claudeCode, scope: .user,
                nativeServerIdentifier: name, executableURL: replacing.executableURL, executable: "claude",
                arguments: ["mcp", "add", "--transport", "http", "--scope", "user", name, "https://example.com/mcp"],
                workingDirectoryPath: nil)
        }
        let before = another("before")
        let after = another("after")
        let alsoAfter = another("also-after")
        func key(_ plan: WorkspaceManagedMCPCommandPlan) -> WorkspaceDeploymentInstallKey {
            .init(artifactID: plan.artifactID, physicalDestinationID: plan.physicalDestinationID)
        }

        let run = WorkspaceDeploymentOperations.run(
            staged: [], managedConnections: [after, replacing, alsoAfter, before],
            order: [key(before), key(replacing), key(after), key(alsoAfter)])

        #expect(
            run.operations.map(\.title) == [
                "Set up 1 connection in Claude Code", "Replace agent-tooling in Claude Code", "Set up 2 connections in Claude Code",
            ])
        #expect(
            run.operations.map { $0.steps.map { run.installKeys[$0.id] } } == [
                [key(before)], [key(replacing), key(replacing)], [key(after), key(alsoAfter)],
            ])
        let replacement = run.operations[1]
        #expect(replacement.steps.map(\.arguments) == [replacing.preArguments ?? [], replacing.arguments])
        #expect(replacement.steps.map(\.title) == ["Remove the old agent-tooling", "Set up agent-tooling"])
        #expect(replacement.kind == .configureMCP)
        #expect(replacement.targetSurfaces == [.claudeCode])
        // If the old registration cannot be removed, the add would only fail
        // on the name, so the replacement stops there, and only there.
        #expect(replacement.steps.map(\.shouldStopOnFailure) == [true, false])
        #expect(run.operations.flatMap(\.steps).filter(\.shouldStopOnFailure).count == 1)
        #expect(run.operations.flatMap(\.steps).allSatisfy { $0.executable == replacing.executableURL.path })
    }

    /// The proof a registration may be replaced: a connection operation's
    /// step that added the connection under its name and succeeded, in the
    /// app it was set up in. The removal a replacement runs first, a failed
    /// add, a configuration edit that names the connection, another
    /// connection's add, and anything another kind of operation did, prove
    /// nothing.
    @Test func onlyASucceededAddIsTheProof() throws {
        let replacing = try Self.plan(replacing: true, replacedCommand: nil)
        let run = WorkspaceDeploymentOperations.run(staged: [], managedConnections: [replacing])
        let operation = try #require(run.operations.first)
        func receipt(
            kind: OperationKind = .configureMCP, _ surface: TargetSurface, _ outcomes: [(String, OperationStepStatus)]
        ) -> OperationReceipt {
            OperationReceipt(
                planID: UUID(), kind: kind, title: "", state: .healthy, targetSurfaces: [surface], results: [],
                verificationSummary: "",
                itemOutcomes: outcomes.map { .init(id: UUID(), title: $0.0, status: $0.1, reason: "") })
        }
        let name = AgentToolingConnection.declaredName

        // The removal succeeded and the add failed: the registration is gone,
        // and nothing shows Agent Tooling set it up.
        let removedOnly = receipt(.claudeCode, operation.steps.map { ($0.title, $0.title.hasPrefix("Remove") ? .succeeded : .failed) })
        #expect(WorkspaceDeploymentOperations.provenConnections(in: [removedOnly]).isEmpty)
        #expect(AgentToolingConnection.provenSurfaces(in: [removedOnly]).isEmpty)

        let proven = WorkspaceDeploymentOperations.provenConnections(in: [
            receipt(.codexCLI, operation.steps.map { ($0.title, .succeeded) }),
            receipt(.geminiCLI, [("Add \(name) to projects./Users/me/site.disabledMcpServers in .claude.json", .succeeded)]),
            receipt(.kiroCLI, [("Set up \(name)", .failed)]),
            receipt(.claudeCode, [("Set up \(name)-beta", .succeeded), ("Set up other", .succeeded)]),
            receipt(kind: .installPlugin, .kiroCLI, [("Set up \(name)", .succeeded)]),
        ])
        #expect(proven == [.codexCLI: [name], .claudeCode: ["\(name)-beta", "other"]])
        #expect(
            AgentToolingConnection.provenSurfaces(in: [removedOnly, receipt(.codexCLI, [("Set up \(name)", .succeeded)])]) == [.codexCLI])
    }

    @Test func theOldCommandIsReadFromTheAppsOwnConfiguration() throws {
        let home = try FixtureHome("replace-old-command")
        defer { home.remove() }
        let old = home.appending("Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp").path(percentEncoded: false)
        try home.plant(".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(old)","args":[]}}}"# + "\n")
        try home.plant(".codex/config.toml", "[mcp_servers.agent-tooling]\ncommand = \"\(old)\"\nargs = []\n")
        let claudeConfig = home.appending(".claude.json")
        let codexConfig = home.appending(".codex/config.toml")
        func observation(_ surface: TargetSurface, _ config: URL) -> TargetObservation {
            TargetObservation(
                surface: surface, installed: true, configurationPaths: [config.path(percentEncoded: false)],
                capabilities: TargetCapabilities(
                    supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
                    supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                    requiresRestart: false, supportsMachineReadableOutput: false))
        }

        #expect(
            WorkspaceManagedMCPCommandPlanning.registeredCommand(
                named: AgentToolingConnection.declaredName, in: observation(.claudeCode, claudeConfig)) == old)
        #expect(
            WorkspaceManagedMCPCommandPlanning.registeredCommand(
                named: AgentToolingConnection.declaredName, in: observation(.codexCLI, codexConfig)) == old)
        #expect(
            WorkspaceManagedMCPCommandPlanning.registeredCommand(
                named: "nothing-here", in: observation(.claudeCode, claudeConfig)) == nil)
    }

    /// The old copy is the one the person's own registration starts, which
    /// the removal takes out: a project's entry of the same name never is.
    @Test func aProjectsEntryIsNotTheRegistrationAReplacementNames() throws {
        let home = try FixtureHome("replace-project-entry")
        defer { home.remove() }
        let own = home.appending("Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp").path(percentEncoded: false)
        let project =
            #""projects":{"/Users/me/site":{"mcpServers":{"agent-tooling":{"type":"stdio","command":"/elsewhere/agent-tooling-mcp","args":[]}}}}"#
        try home.plant("project-only.json", "{\(project)}\n")
        try home.plant(
            "both.json", #"{"mcpServers":{"agent-tooling":{"type":"stdio","command":"\#(own)","args":[]}},"# + project + "}\n")
        func observation(_ file: String) -> TargetObservation {
            TargetObservation(
                surface: .claudeCode, installed: true, configurationPaths: [home.appending(file).path(percentEncoded: false)],
                capabilities: TargetCapabilities(
                    supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
                    supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                    requiresRestart: false, supportsMachineReadableOutput: false))
        }

        #expect(
            WorkspaceManagedMCPCommandPlanning.registeredCommand(
                named: AgentToolingConnection.declaredName, in: observation("project-only.json")) == nil)
        #expect(
            WorkspaceManagedMCPCommandPlanning.registeredCommand(
                named: AgentToolingConnection.declaredName, in: observation("both.json")) == own)
    }

    // MARK: - The plan

    /// Agent Tooling's own connection for Claude Code on this Mac, planned
    /// as the review plans it.
    private static func plan(replacing: Bool, replacedCommand: String?) throws -> WorkspaceManagedMCPCommandPlan {
        let artifactID = ArtifactID(fixtureUUID("00000000-0000-0000-0000-000000000501"))
        let deviceID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-000000000502"))
        let physicalID = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-000000000503"))
        let destination = PortableDestination(surface: .claudeCode, scope: .user, deviceIDs: [deviceID])
        let document = try WorkspaceDocumentCoding.seal(
            PortableWorkspaceDocument(
                workspaceID: WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-000000000504")),
                revision: .init(writerID: WorkspaceObjectID()),
                artifacts: [
                    ArtifactRecord(
                        identity: .init(id: artifactID, kind: .mcpServer, displayName: AgentToolingConnection.displayName),
                        authority: .centralPersonal, declaredName: AgentToolingConnection.declaredName)
                ],
                assignments: [
                    AssignmentContribution(
                        id: WorkspaceObjectID(), artifactID: artifactID, destination: destination, reason: .manual,
                        desiredPresence: true, desiredEnabled: nil)
                ],
                mcpDefinitions: [.init(artifactID: artifactID, connection: .deviceBound(transport: .stdio))]))
        let capability = TargetCapabilityEvidence(
            surface: .claudeCode, installedClientVersion: "2.1.304", adapterContractVersion: 1, component: .mcpServer,
            transport: MCPTransport.stdio.rawValue, scopes: [.user], support: .supported,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let device = DeviceWorkspaceState(
            workspaceID: document.workspaceID, deviceID: deviceID, capabilityEvidence: [capability],
            mcpBindings: [.init(artifactID: artifactID, destination: .stdio(executable: helper, arguments: []))])
        let target = ResolvedAssignmentTarget(
            selector: .init(destination: destination), physicalDestinationID: physicalID, installedClientVersion: "2.1.304",
            adapterContractVersion: 1, componentContexts: [.init(component: .mcpServer, transport: MCPTransport.stdio.rawValue)])
        let resolved = WorkspaceAssignmentResolver.resolve(
            artifacts: document.artifacts, contributions: document.assignments, currentDeviceID: deviceID, targets: [target],
            capabilityEvidence: device.capabilityEvidence, portableMCPDefinitions: document.mcpDefinitions ?? [],
            deviceMCPBindings: device.mcpBindings ?? [])
        let requirement = try #require(resolved.requirements.first)
        return try WorkspaceManagedMCPCommandPlanning.plan(
            document: document, device: device, requirement: requirement, resolvedTargets: [target], target: target,
            capability: capability, nativeServerIdentifier: AgentToolingConnection.declaredName,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/claude"), replacing: replacing, replacedCommand: replacedCommand)
    }
}
