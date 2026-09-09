import Foundation

/// Plugins retain their native installation and update owner. A supported
/// command can be reviewed here; other clients keep their own update flow.
public struct PluginUpdateRoute: Equatable, Sendable {
    public let client: ClientKind
    public let canUpdateHere: Bool
    public let detail: String

    public var actionTitle: String {
        canUpdateHere ? "Review update…" : "Update in \(client.rawValue)…"
    }
}

extension AppModel {
    public func pluginUpdateRoute(pluginID: String, client: ClientKind) -> PluginUpdateRoute? {
        guard let plugin = visiblePlugins.first(where: { $0.id == pluginID }),
            plugin.clients.contains(where: { $0.client == client && $0.reportsLocalPresence })
        else { return nil }

        let observations = visibleTargetObservations.filter { $0.surface.client == client }
        let scopes = Set(observations.compactMap { $0.pluginMetadata[pluginID]?.scope.lowercased() })
        let hasCommand = observations.contains(where: \.isCommandAvailable)
        let safeIdentifier = OperationCommandPolicy.isSafePluginIdentifier(pluginID)
        if client == .claude, scopes == ["user"], hasCommand, safeIdentifier {
            return PluginUpdateRoute(
                client: client, canUpdateHere: true,
                detail: "Claude Code updates this plugin from its configured marketplace, keeping its included skills and tools together. Start a fresh Claude Code session after updating."
            )
        }

        let detail: String
        switch client {
        case .claude:
            if scopes.isEmpty || scopes == ["this mac"] {
                detail = "Check plugins to confirm this installation's scope, or update it in Claude Code. Its plugin files and included tools remain managed by Claude Code."
            } else if scopes != ["user"] {
                detail = "Update this plugin in Claude Code at its existing \(scopes.sorted().joined(separator: "/")) scope. Its included skills and tools stay with the plugin."
            } else {
                detail = "Update this plugin in Claude Code, then check plugins here. Its native update command is not available for this installation."
            }
        case .codex:
            detail = "Codex manages this plugin and its included tools. Review plugin updates in Codex, then check plugins here to see the installed revision."
        case .gemini:
            detail = "Gemini CLI manages this extension and its included tools. Update it through Gemini CLI, then check plugins here to see the installed revision."
        }
        return PluginUpdateRoute(client: client, canUpdateHere: false, detail: detail)
    }

    /// Uses the installed plugin's exact native identifier. Updating a plugin
    /// never adopts its bundled skills into independent managed packages.
    public func planPluginUpdate(pluginID: String, client: ClientKind) {
        guard requireEnabledClients([client]), ensureReadyForChange() else { return }
        guard let plugin = visiblePlugins.first(where: { $0.id == pluginID }),
            let route = pluginUpdateRoute(pluginID: pluginID, client: client)
        else {
            presentError("This plugin is no longer reported as installed in \(client.rawValue). Check plugins and try again.")
            return
        }
        if managedPolicies.contains(where: {
            $0.blockedPluginIDs.contains(plugin.name) || $0.blockedPluginIDs.contains(plugin.id)
        }) {
            presentError("A managed policy blocks changes to \(plugin.name). Review the policy source in Settings.")
            return
        }

        guard route.canUpdateHere else {
            pendingPlan = OperationPlan(
                kind: .installPlugin,
                title: "Update \(plugin.name) in \(client.rawValue)",
                summary: route.detail,
                targetSurfaces: [surface(for: client)],
                scope: .workspace,
                steps: [
                    OperationStep(
                        kind: .manual, title: "Use \(client.rawValue)'s plugin manager",
                        detail: route.detail, requiresUserAction: true
                    )
                ],
                requiresConfirmation: false
            )
            return
        }

        pendingPlan = OperationPlan(
            kind: .installPlugin,
            title: "Update \(plugin.name) in Claude Code",
            summary: route.detail,
            targetSurfaces: [surface(for: .claude)],
            scope: .user,
            steps: [
                OperationStep(
                    kind: .command, title: "Update through Claude Code",
                    detail: "Updates the exact installed plugin \(pluginID) at user scope using Claude Code's native marketplace source. Any additional marketplace command approval stays with Claude Code.",
                    executable: "claude", arguments: ["plugin", "update", pluginID, "--scope", "user"],
                    isReversible: false
                ),
                OperationStep(
                    kind: .scan, title: "Check the installed plugin revision",
                    detail: "Re-scan the native plugin inventory and its included skills after the update.",
                    isReversible: false
                ),
                OperationStep(
                    kind: .manual, title: "Start a fresh Claude Code session",
                    detail: "Claude Code loads the updated plugin in a fresh session. Confirm the plugin's included tools there.",
                    requiresUserAction: true
                )
            ]
        )
    }
}
