import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// What the planner is told about the connections each app holds, on the
/// sample world at Let your apps ask's review: only a registration the app
/// holds for the person counts as the connection being there. A plugin's
/// server of the same name, or one only a project's settings name, is some
/// other server, so the step is planned as new; an entry under the name that
/// is an address is replaced; and a request at a project's scope is told
/// nothing, as before this read existed.
@Suite("Deployment session · connections", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceDeploymentSessionConnectionsTests {
    @Test func aPluginsOrAProjectsServerOfTheSameNameIsPlannedAsNew() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        let own = try #require(sample.decisions.helperArtifactID)
        try fixture.world.home.plant(
            ".claude.json",
            #"{"projects":{"/Users/example/work":{"mcpServers":{"agent-tooling":{"type":"stdio","command":"/Users/example/old/agent-tooling-mcp","args":[]}}}}}"#
        )
        await Self.register(
            in: sample.workspace,
            [
                .claudeCode: ("Claude Code configuration", fixture.world.home.appending(".claude.json")),
                .codexCLI: ("agent-tooling@openai-curated", nil),
            ])

        let steps = try await Self.connectionSteps(of: own, in: sample.workspace)

        #expect(Set(steps.map(\.surface)) == [.codexCLI, .claudeCode])
        #expect(steps.allSatisfy { $0.action == .configureManagedConnection(transport: .stdio, replacesExisting: false) })
    }

    @Test func anEntryUnderTheNameThatIsAnAddressIsReplaced() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterAsk)
        let own = try #require(sample.decisions.helperArtifactID)
        try fixture.world.home.plant(
            ".claude.json", #"{"mcpServers":{"agent-tooling":{"type":"http","url":"https://example.com/mcp"}}}"#)
        await Self.register(
            in: sample.workspace, [.claudeCode: ("Claude Code configuration", fixture.world.home.appending(".claude.json"))])

        let steps = try await Self.connectionSteps(of: own, in: sample.workspace)

        #expect(
            steps.first { $0.surface == .claudeCode }?.action
                == .configureManagedConnection(transport: .stdio, replacesExisting: true))
        #expect(
            steps.first { $0.surface == .codexCLI }?.action
                == .configureManagedConnection(transport: .stdio, replacesExisting: false))
    }

    /// A request at a project's scope, or any scope but the person's own, is
    /// told nothing, whatever the app registers for the person, so the
    /// planner plans it as it always did. At the person's own scope it is
    /// there when the app registers it, matching when it starts the bound
    /// command.
    @Test func onlyARequestAtThePersonsOwnScopeIsToldWhatTheAppHolds() throws {
        let key = WorkspaceDeploymentInstallKey(artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID())
        let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
        let registrations = [AgentToolingConnection.declaredName: UserScopeMCPRegistration(command: helper)]
        let binding = DeviceMCPDefinitionBinding(
            artifactID: key.artifactID, destination: .stdio(executable: helper, arguments: []), authenticationRequirement: .none)
        func reported(_ name: String, at scope: ToolingScope) -> WorkspaceDeploymentObservation? {
            WorkspaceDeploymentSession.reportedConnection(
                key, named: name, scope: scope, registrations: registrations, binding: binding)
        }

        for scope in [ToolingScope.project, .localProject, .workspace] {
            #expect(reported(AgentToolingConnection.declaredName, at: scope) == nil, "\(scope)")
        }
        let present = try #require(reported(AgentToolingConnection.declaredName, at: .user))
        #expect(present.isPresent && present.isEnabled == true && present.connectionMatches == true)
        let absent = try #require(reported("sentry", at: .user))
        #expect(!absent.isPresent && absent.connectionMatches == nil)
    }

    // MARK: - The sample world

    @Test func changedOrUnreadableArgumentsCannotProveRegistrationOwnership() throws {
        let key = WorkspaceDeploymentInstallKey(artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID())
        let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
        let binding = DeviceMCPDefinitionBinding(
            artifactID: key.artifactID, destination: .stdio(executable: helper, arguments: []), authenticationRequirement: .none)
        let variants: [[String]?] = [["--help"], nil]
        for arguments in variants {
            let observation = try #require(
                WorkspaceDeploymentSession.reportedConnection(
                    key, named: AgentToolingConnection.declaredName, scope: .user,
                    registrations: [AgentToolingConnection.declaredName: .init(command: helper, arguments: arguments)], binding: binding))
            #expect(observation.isPresent)
            #expect(observation.connectionMatches != true)
        }
    }

    @Test func aManagedConnectionMustMatchItsBoundArguments() throws {
        let key = WorkspaceDeploymentInstallKey(artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID())
        let binding = DeviceMCPDefinitionBinding(
            artifactID: key.artifactID, destination: .stdio(executable: "/usr/local/bin/server", arguments: ["serve", "--local"]),
            authenticationRequirement: .none)
        for arguments in [["serve", "--local"], ["serve", "--remote"]] {
            let observation = try #require(
                WorkspaceDeploymentSession.reportedConnection(
                    key, named: "example", scope: .user,
                    registrations: ["example": .init(command: "/usr/local/bin/server", arguments: arguments)], binding: binding))
            #expect(observation.connectionMatches == (arguments == ["serve", "--local"]))
        }
    }

    /// Records that each app's last check found a server named
    /// `agent-tooling` from `source`, reading the file given beside it.
    private static func register(
        in workspace: WorkspaceLaunch.Workspace, _ sources: [TargetSurface: (source: String, file: URL?)]
    ) async {
        await workspace.device.adopt(
            workspace.device.observations.map { observation in
                guard let registration = sources[observation.surface] else { return observation }
                var registered = observation
                registered.discoveredMCPServers.append(AgentToolingConnection.declaredName)
                registered.mcpMetadata[AgentToolingConnection.declaredName] = .init(
                    transport: "stdio", authentication: "Not inferred", source: registration.source)
                if let path = registration.file?.path(percentEncoded: false), !registered.configurationPaths.contains(path) {
                    registered.configurationPaths.append(path)
                }
                return registered
            })
        #expect(workspace.device.errorMessage == nil, "the check was recorded")
    }

    /// The prepared plan's steps for the connection `own`, over the library
    /// as it stands now, the check just recorded included.
    private static func connectionSteps(
        of own: ArtifactID, in workspace: WorkspaceLaunch.Workspace
    ) async throws -> [WorkspaceDeploymentItem] {
        await workspace.library.refresh()
        await workspace.deployment.prepare()
        return try #require(workspace.deployment.plan).items.filter { $0.artifactID == own }
    }
}
