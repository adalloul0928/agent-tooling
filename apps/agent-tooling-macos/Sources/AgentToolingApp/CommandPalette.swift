import AgentToolingCore
import SwiftUI

/// What activating a palette result does.
///
/// The palette itself never changes anything: it hands one of these back to the
/// shell, which navigates, or asks a session for the same reviewed operation the
/// screen's own button would.
enum CommandPaletteOutcome: Equatable {
    case navigate(AppSection)
    case openClient(ClientKind)
    case screenRequest(ScreenRequest)
    case openSkill(String)
    /// Read this Mac's apps again. Reads only.
    case checkSetup
    /// Prepare one plan for everything out of step, and show it. Preparing is
    /// not applying; the Apps screen still asks before anything is written.
    case reviewSync
}

/// A screen-specific request the shell hands to a screen it owns, so a palette
/// result can land on the right row or open the right sheet.
enum ScreenRequest: Equatable {
    case addMCPServer
    case pasteImport
    case selectMCPServer(String)
    case selectPlugin(String)
    case selectReceipt(String)

    var section: AppSection {
        switch self {
        case .addMCPServer, .pasteImport, .selectMCPServer: .mcpServers
        case .selectPlugin: .plugins
        case .selectReceipt: .activity
        }
    }

    /// The one row this request is about, when it is about a row at all.
    var itemID: String? {
        switch self {
        case .selectMCPServer(let id), .selectPlugin(let id), .selectReceipt(let id): id
        case .addMCPServer, .pasteImport: nil
        }
    }
}

struct CommandPaletteItem: Identifiable, PaletteSearchable {
    let id: String
    let title: String
    let subtitle: String
    let contextLabel: String
    let kind: ToolingKind?
    let symbol: String
    let keywords: [String]
    let priority: Int
    let outcome: CommandPaletteOutcome

    var paletteTitle: String { title }
    var paletteSubtitle: String { subtitle }
    var paletteKeywords: [String] { keywords }
    var palettePriority: Int { priority }

    var client: ClientKind? {
        guard case .openClient(let client) = outcome else { return nil }
        return client
    }
}

/// Every named object the app already holds, in one list. Built once when the
/// palette opens, from state that is already in memory: opening the palette
/// reads nothing from disk and starts no scan.
enum CommandPaletteCatalog {
    @MainActor
    static func items(for workspace: WorkspaceLaunch.Workspace) -> [CommandPaletteItem] {
        let library = workspace.library.state?.library
        return actions() + sections() + clients(for: workspace)
            + rows(library?.filteredRows(matching: "") ?? [])
            + presets(library?.presets ?? [])
            + projects(library?.projects ?? [])
            + receipts(workspace)
    }

    private static func actions() -> [CommandPaletteItem] {
        [
            CommandPaletteItem(
                id: "action.checkSetup",
                title: "Check Setup",
                subtitle: "Read this Mac again for what each app actually has",
                contextLabel: "Action",
                kind: nil,
                symbol: "stethoscope",
                keywords: ["doctor", "scan", "health", "check", "clients"],
                priority: 100,
                outcome: .checkSetup),
            CommandPaletteItem(
                id: "action.reviewSync",
                title: "Review Sync",
                subtitle: "Prepare one plan for everything that is out of step",
                contextLabel: "Action",
                kind: nil,
                symbol: "arrow.triangle.2.circlepath",
                keywords: ["sync", "install", "plan", "reconcile", "apps"],
                priority: 100,
                outcome: .reviewSync),
        ]
    }

    private static func sections() -> [CommandPaletteItem] {
        AppSection.allCases.map { section in
            CommandPaletteItem(
                id: "section.\(section.id)",
                title: section.navigationTitle,
                subtitle: "Screen",
                contextLabel: "Go to",
                kind: nil,
                symbol: section.symbol,
                keywords: [section.rawValue, section.workspaceTitle ?? ""],
                priority: 60,
                outcome: .navigate(section))
        }
    }

    /// Only the apps this Mac manages. An app somebody has switched off is not a
    /// place a search result can send them.
    @MainActor
    private static func clients(for workspace: WorkspaceLaunch.Workspace) -> [CommandPaletteItem] {
        workspace.device.availableClients.filter(workspace.device.isEnabled).map { client in
            CommandPaletteItem(
                id: "client.\(client.id)",
                title: client.rawValue,
                subtitle: "Show only this app's local state",
                contextLabel: "Apps",
                kind: nil,
                symbol: "desktopcomputer",
                keywords: ["client", "app", "local", "sync", "scope"],
                priority: 70,
                outcome: .openClient(client))
        }
    }

    /// One entry per library row, opening the screen that row belongs to.
    private static func rows(_ rows: [WorkspaceLibraryReadModelRow]) -> [CommandPaletteItem] {
        rows.compactMap { row in
            let identifier = row.artifactID.rawValue.uuidString.lowercased()
            switch row.kind {
            case .skill:
                return CommandPaletteItem(
                    id: "skill.\(identifier)",
                    title: row.displayName,
                    subtitle: "\(row.ownershipLabel) · Library",
                    contextLabel: "Library",
                    kind: .skill,
                    symbol: "doc.text",
                    keywords: [row.sourceLabel, row.parentPluginLabel].compactMap { $0 },
                    priority: 40,
                    outcome: .openSkill(identifier))
            case .nativePlugin, .package:
                return CommandPaletteItem(
                    id: "plugin.\(identifier)",
                    title: row.displayName,
                    subtitle: "\(row.ownershipLabel) · Plugins",
                    contextLabel: "Plugins",
                    kind: .plugin,
                    symbol: "puzzlepiece.extension",
                    keywords: [row.sourceLabel].compactMap { $0 }
                        + row.includedChildren.map(\.displayName),
                    priority: 40,
                    outcome: .screenRequest(.selectPlugin(identifier)))
            case .mcpServer:
                return CommandPaletteItem(
                    id: "mcp.\(identifier)",
                    title: row.displayName,
                    subtitle: "\(row.ownershipLabel) · Connections",
                    contextLabel: "Connections",
                    kind: .mcpServer,
                    symbol: "server.rack",
                    keywords: [row.sourceLabel].compactMap { $0 },
                    priority: 40,
                    outcome: .screenRequest(.selectMCPServer(identifier)))
            case .preset, .logicalProject:
                // Neither is a library row; both are listed from their own
                // collection below, so listing them here would double them up.
                return nil
            }
        }
    }

    private static func presets(_ presets: [WorkspaceLibraryPresetReadModel]) -> [CommandPaletteItem] {
        presets.map { preset in
            CommandPaletteItem(
                id: "preset.\(preset.id.rawValue.uuidString.lowercased())",
                title: preset.name,
                subtitle: preset.memberArtifactIDs.count == 1
                    ? "Preset · 1 item" : "Preset · \(preset.memberArtifactIDs.count) items",
                contextLabel: "Presets",
                kind: .collection,
                symbol: AppSection.presets.symbol,
                keywords: ["preset", "shelf", "collection"],
                priority: 30,
                outcome: .navigate(.presets))
        }
    }

    private static func projects(_ projects: [WorkspaceLibraryProjectReadModel]) -> [CommandPaletteItem] {
        projects.map { project in
            CommandPaletteItem(
                id: "project.\(project.id.rawValue.uuidString.lowercased())",
                title: project.name,
                subtitle: "Project",
                contextLabel: "Projects",
                kind: nil,
                symbol: AppSection.projects.symbol,
                keywords: ["project"] + project.repositoryHints,
                priority: 30,
                outcome: .navigate(.projects))
        }
    }

    /// The most recent receipts, so a reviewed operation is one search away.
    /// Bounded, so the palette does not fill with a workspace's entire
    /// history — the Activity screen itself is where the rest live.
    @MainActor
    private static func receipts(_ workspace: WorkspaceLaunch.Workspace) -> [CommandPaletteItem] {
        let receipts = (try? workspace.store.operationReceipts(limit: 20)) ?? []
        return receipts.map { receipt in
            CommandPaletteItem(
                id: "receipt.\(receipt.id.uuidString.lowercased())",
                title: receipt.title,
                subtitle: "\(receipt.outcomeTally) · Activity",
                contextLabel: "Activity",
                kind: .activity,
                symbol: AppSection.activity.symbol,
                keywords: ["receipt", "activity", receipt.verificationSummary],
                priority: 30,
                outcome: .screenRequest(.selectReceipt(receipt.id.uuidString.lowercased())))
        }
    }
}

/// One palette over every screen. Typing filters, the arrow keys move, Return
/// activates, Escape closes; nothing here writes.
struct CommandPaletteView: View {
    let workspace: WorkspaceLaunch.Workspace
    let onActivate: (CommandPaletteOutcome) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var items: [CommandPaletteItem] = []
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var results: [CommandPaletteItem] { CommandPaletteMatcher.rank(items, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultList
            Divider()
            hints
        }
        .frame(width: 660, height: 460)
        .background(AgentTheme.contentBackground)
        .onAppear {
            items = CommandPaletteCatalog.items(for: workspace)
            searchFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onExitCommand(perform: onClose)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search apps, tools, presets, projects, and actions", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel("Search everything")
                .onSubmit(activateHighlighted)
                .onKeyPress(.downArrow) {
                    move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1)
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing matches \(query)")
                    .font(.callout.weight(.medium))
                Text("Search by name, or type an action such as Check Setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            Button {
                                highlighted = index
                                activateHighlighted()
                            } label: {
                                CommandPaletteRow(item: item, selected: index == highlighted)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .help("Open \(item.title) in \(item.contextLabel)")
                            .accessibilityLabel("\(item.title), \(item.subtitle)")
                            .accessibilityValue(index == highlighted ? "Selected" : "")
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
                .onChange(of: highlighted) { _, index in
                    guard results.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(results[index].id, anchor: .center) }
                }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            Label("Move", systemImage: "arrow.up.arrow.down")
            Label("Open", systemImage: "return")
            Label("Close", systemImage: "escape")
            Spacer()
            Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func move(by offset: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), results.count - 1)
    }

    private func activateHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        onActivate(results[highlighted].outcome)
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            if let client = item.client {
                ClientBrandIcon(client: client, size: 18)
                    .frame(width: 24, height: 24)
            } else if let kind = item.kind {
                KindTile(kind: kind, size: 24)
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(item.contextLabel)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AgentTheme.blue)
            }
        }
        .contentShape(Rectangle())
    }
}
