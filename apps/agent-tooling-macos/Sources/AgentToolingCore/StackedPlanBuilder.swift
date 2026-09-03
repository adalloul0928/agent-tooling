import Foundation

public enum StackedPlanError: LocalizedError, Equatable, Sendable {
    case emptySelection
    case noTargets
    case mixedScopes([String])
    case missingProjectRoot(String)
    case invalidDestination(String, String)
    case noRemovalRoute(String, ClientKind)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select at least one item before building a plan."
        case .noTargets:
            "Choose at least one app before building a plan."
        case .mixedScopes(let scopes):
            "The selection mixes \(scopes.joined(separator: " and ")) scopes. Build one plan per scope so the review sheet can name where it writes."
        case .missingProjectRoot(let name):
            "\(name) has no project folder. Open it and choose the folder before adding it to a stack."
        case .invalidDestination(let name, let reason):
            "\(name) cannot be configured: \(reason)"
        case .noRemovalRoute(let name, let client):
            "\(client.rawValue) exposes no verified removal command for \(name). Refresh Marketplace, then remove it from its own screen."
        }
    }
}

/// Builds one reviewed plan from several picks. A stack changes how many steps
/// a person reviews at once, never what may run: the composed plan goes through
/// the same review sheet, and the engine still checks every command against its
/// fixed allowlist.
public enum StackedPlanBuilder {
    public static let maximumSelection = 25

    public static func mcpConfigurationPlan(
        servers: [MCPServer],
        targets: Set<ClientKind>,
        availableClients: Set<ClientKind>
    ) throws -> OperationPlan {
        guard !servers.isEmpty else { throw StackedPlanError.emptySelection }
        guard !targets.isEmpty else { throw StackedPlanError.noTargets }
        let selection = Array(servers.prefix(maximumSelection))
        let scopes = Set(selection.map(\.scope))
        guard scopes.count == 1, let scopeName = scopes.first else {
            throw StackedPlanError.mixedScopes(scopes.sorted())
        }
        let scope = ToolingScope.allCases.first { $0.displayName == scopeName } ?? .user

        var steps: [OperationStep] = []
        for server in selection.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let destination: ValidatedMCPDestination
            do {
                destination = try MCPDefinitionValidator.validate(server.endpoint, transport: server.transport)
            } catch {
                throw StackedPlanError.invalidDestination(server.name, error.localizedDescription)
            }
            let workingDirectory: String?
            if scope == .user {
                workingDirectory = nil
            } else {
                guard let projectRoot = server.projectRoot else { throw StackedPlanError.missingProjectRoot(server.name) }
                workingDirectory = projectRoot
            }
            for client in targets.sorted(by: { $0.rawValue < $1.rawValue }) {
                steps.append(
                    configurationStep(
                        server: server,
                        client: client,
                        destination: destination,
                        scope: scope,
                        workingDirectory: workingDirectory,
                        isClientAvailable: availableClients.contains(client)
                    ))
            }
        }
        steps.append(
            OperationStep(
                kind: .scan,
                title: "Re-scan local MCP configuration",
                detail:
                    "Confirm each server is present in every selected local client configuration; this does not prove remote health or OAuth."
            ))

        let serverNames = selection.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return OperationPlan(
            kind: .configureMCP,
            title: "Configure \(selection.count) MCP server\(selection.count == 1 ? "" : "s")",
            summary:
                "\(serverNames.joined(separator: ", ")) in \(targets.count) app\(targets.count == 1 ? "" : "s"), reviewed as one plan. Secrets and OAuth tokens are never placed in the plan or copied between apps.",
            targetSurfaces: targets.sorted(by: { $0.rawValue < $1.rawValue }).map(surface(for:)),
            scope: scope,
            steps: steps
        )
    }

    public static func pluginRemovalPlan(
        plugins: [Plugin],
        client: ClientKind,
        packages: [MarketplacePackage]
    ) throws -> OperationPlan {
        guard !plugins.isEmpty else { throw StackedPlanError.emptySelection }
        let selection = Array(plugins.prefix(maximumSelection))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let catalogPrefix = catalogPrefix(for: client)

        var steps: [OperationStep] = []
        for plugin in selection {
            guard
                let package = packages.first(where: {
                    $0.supportedClients.contains(client) && $0.id == "\(catalogPrefix):\(plugin.id)"
                }),
                let route = package.nativeInstalls.first(where: { $0.client == client }),
                let removal = route.removalArguments
            else {
                throw StackedPlanError.noRemovalRoute(plugin.name, client)
            }
            steps.append(
                OperationStep(
                    kind: .command,
                    title: "Remove \(plugin.name) from \(client.rawValue)",
                    detail: "Removes this exact plugin identifier through \(client.rawValue)'s native plugin manager.",
                    executable: route.executable,
                    arguments: removal,
                    isReversible: false
                ))
        }
        steps.append(
            OperationStep(
                kind: .scan,
                title: "Re-scan \(client.rawValue)",
                detail: "Confirm local installation state. This does not prove remote authentication or a live connector.",
                isReversible: false
            ))

        return OperationPlan(
            kind: .installPlugin,
            title: "Remove \(selection.count) plugin\(selection.count == 1 ? "" : "s") from \(client.rawValue)",
            summary:
                "\(selection.map(\.name).joined(separator: ", ")) removed through \(client.rawValue)'s own plugin manager, reviewed as one plan.",
            targetSurfaces: [surface(for: client)],
            scope: .user,
            steps: steps
        )
    }

    private static func configurationStep(
        server: MCPServer,
        client: ClientKind,
        destination: ValidatedMCPDestination,
        scope: ToolingScope,
        workingDirectory: String?,
        isClientAvailable: Bool
    ) -> OperationStep {
        guard isClientAvailable else {
            return OperationStep(
                kind: .manual,
                title: "Install \(client.rawValue) before configuring \(server.name)",
                detail:
                    "The local CLI was not found. The desired MCP definition remains saved; run Check Setup after installing \(client.rawValue), then review this configuration again.",
                requiresUserAction: true
            )
        }
        guard MCPClientCommand.supportsScope(scope, client: client) else {
            return OperationStep(
                kind: .manual,
                title: "Configure \(server.name) at \(server.scope) scope in Codex",
                detail:
                    "The current Codex MCP CLI exposes no scope flag. Review the project-specific Codex configuration location before adding this server; Agent Tooling will not silently place a project server in global config.",
                requiresUserAction: true
            )
        }
        return OperationStep(
            kind: .command,
            title: "Configure \(server.name) for \(client.rawValue)",
            detail:
                "Uses \(client.rawValue)'s native MCP command at \(server.scope.lowercased()) scope. Authentication and tool approval remain separate.",
            executable: executable(for: client),
            arguments: MCPClientCommand.addArguments(
                serverID: server.id,
                transport: server.transport,
                destination: destination,
                client: client,
                scope: scope
            ),
            currentDirectoryPath: workingDirectory,
            projectRootPath: workingDirectory
        )
    }

    private static func catalogPrefix(for client: ClientKind) -> String {
        switch client {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }

    private static func executable(for client: ClientKind) -> String {
        MCPClientCommand.executable(for: client)
    }

    private static func surface(for client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }
}
