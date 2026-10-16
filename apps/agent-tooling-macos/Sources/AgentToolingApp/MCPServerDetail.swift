import AgentToolingCore
import SwiftUI

// MARK: - Stack

/// Several picks, one review. It says exactly what will be reviewed and refuses
/// combinations this workspace cannot describe honestly in a single batch.
///
/// Module-internal rather than file-private so a render test can prove that a
/// stack containing something nobody may assign says so instead of offering it.
struct MCPStackPane: View {
    let entries: [MCPConnectionEntry]
    let isBusy: Bool
    let onAssign: () -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(spacing: Space.xl) {
                    KindTile(kind: .mcpServer, size: Size.tileLarge)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("\(CountNoun.connection.phrase(entries.count)) selected").font(AgentFont.title)
                        Text("Review them as one assignment instead of one each.")
                            .font(AgentFont.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review one assignment", action: onAssign)
                        .primaryActionStyle()
                        .disabled(assignable.isEmpty || isBusy)
                }

                if assignable.count < entries.count {
                    AttentionBanner(
                        title: "Some of these cannot be assigned here",
                        message:
                            "\(entries.count - assignable.count) of \(entries.count) are owned by an app or a plugin, "
                            + "so this workspace has no say in where they are used. They stay out of the review."
                    ) {
                        Button("Keep one", action: onClear)
                            .secondaryActionStyle()
                            .controlSize(.small)
                    }
                }

                TitledCard("In this stack", count: "\(entries.count)") {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        InfoRow(entry.displayName, detail: entry.clause) {
                            KindTile(kind: .mcpServer, size: Size.tile, ghost: !entry.isManaged)
                        } trailing: {
                            StatusBadge(state: entry.verdict.state, text: entry.verdict.text)
                        }
                        if index < entries.count - 1 { Hairline() }
                    }
                }

                Text(
                    "Saves where these connections should be used. Installing them in an app is a separate reviewed step "
                        + "on the Apps screen; nothing here writes to a client."
                )
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
            }
            .padding(Space.xxxl)
        }
    }

    private var assignable: [MCPConnectionEntry] { entries.filter(\.isAssignable) }
}

// MARK: - Detail

/// Module-internal rather than file-private: this is the pane where a saved
/// request could most easily be mistaken for an installation, so a render test
/// gets to hold it to that.
struct MCPDetailView: View {
    let entry: MCPConnectionEntry
    let workspaceRoot: URL
    let isBusy: Bool
    let onAssign: () -> Void
    let onRemove: ([WorkspaceObjectID]) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                if !entry.isAssignable, let explanation = entry.assignmentExplanation {
                    AttentionBanner(title: "This one is not yours to assign", message: explanation)
                }

                TitledCard("Where it was asked for", count: "\(entry.requestedAssignments.count)") {
                    if entry.requestedAssignments.isEmpty {
                        LabeledValueRow("Assignments") {
                            Text("Nobody has asked for this connection anywhere yet.")
                                .font(AgentFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ClientStatusRows(clients: entry.server.clients)
                    }
                }

                if !entry.definedBy.isEmpty { definedByCard }

                TitledCard("Origin") {
                    LabeledValueRow("Managed by") { Text(entry.ownershipLabel) }
                    if let plugin = entry.parentPluginLabel {
                        Hairline()
                        LabeledValueRow("Plugin") { Text(plugin) }
                    }
                    if let source = entry.sourceLabel {
                        Hairline()
                        LabeledValueRow("Source") { Text(source).lineLimit(1).truncationMode(.middle) }
                    }
                    ForEach(entry.nativeRoutes, id: \.client) { route in
                        Hairline()
                        LabeledValueRow(route.client.rawValue) {
                            Text(route.externalPluginID)
                                .font(AgentFont.mono)
                                .textSelection(.enabled)
                        }
                    }
                    Hairline()
                    LabeledValueRow("Workspace") {
                        LocationText(path: workspaceRoot.path(percentEncoded: false), label: "This Mac's workspace")
                    }
                }

                HStack(alignment: .top, spacing: Space.md) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(
                        "How to reach \(entry.displayName) — its command or address, its transport and its "
                            + "credentials — lives in each app's own configuration file, not in this workspace. "
                            + "Agent Tooling records that the connection exists and where it was asked for."
                    )
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.xxs)

                MCPServerCapabilitiesPane(server: entry.server)
            }
            .padding(Space.xxxl)
        }
    }

    /// Where each app gets this server. An app that gets it from several
    /// places runs each one separately unless they are configured identically,
    /// so that case is called out rather than left in a list.
    private var definedByCard: some View {
        let repeated = entry.definedBy.filter { $0.sources.count > 1 }
        return TitledCard("Defined by") {
            ForEach(Array(entry.definedBy.enumerated()), id: \.element.id) { index, found in
                if index > 0 { Hairline() }
                LabeledValueRow(found.client.rawValue) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(found.sources, id: \.self) { source in
                            Text(MCPDefinitionSources.label(source)).lineLimit(1).truncationMode(.middle).help(source)
                        }
                    }
                }
            }
            if !repeated.isEmpty {
                Hairline()
                HStack(alignment: .top, spacing: Space.md) {
                    Image(systemName: "square.on.square").foregroundStyle(AgentTheme.warning)
                    Text(
                        "\(repeated.map(\.client.rawValue).joined(separator: " and ")) "
                            + "\(repeated.count == 1 ? "gets" : "get") this connection from more than one place. "
                            + "Unless two definitions are identical, each one starts its own process and lists its own tools. "
                            + "A copy in the app's own configuration is yours to remove; a plugin's comes and goes with the plugin."
                    )
                    .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.xl) {
            KindTile(kind: .mcpServer, size: Size.tileLarge, ghost: !entry.isManaged)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(entry.displayName).font(AgentFont.title)
                Text(entry.observedDescription ?? entry.clause)
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            Spacer()
            if entry.isAssignable {
                Button("Assign…", action: onAssign)
                    .primaryActionStyle()
                    .disabled(isBusy)
            }
            if !entry.requestedAssignments.isEmpty {
                Menu("Stop asking…") {
                    ForEach(entry.requestedAssignments) { requested in
                        Button(requested.destination.surface.displayName, role: .destructive) {
                            onRemove([requested.id])
                        }
                    }
                    if entry.requestedAssignments.count > 1 {
                        Divider()
                        Button("Everywhere", role: .destructive) {
                            onRemove(entry.requestedAssignments.map(\.id))
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Stop asking for \(entry.displayName)")
                .disabled(isBusy)
            }
        }
    }
}
