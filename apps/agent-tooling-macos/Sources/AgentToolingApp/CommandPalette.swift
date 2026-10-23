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
    case checkApps
    /// Read each managed app's connections again and show the Health screen.
    /// Reads only.
    case checkConnectionHealth
    /// Prepare one plan for everything out of step, and show it. Preparing is
    /// not applying; the Apps screen still asks before anything is written.
    case reviewSync
    /// Open the setup stage again at Your apps. Nothing is read or changed
    /// until the person walks it, and nothing is written until its review.
    case setUpThisMac
}

/// A screen-specific request the shell hands to a screen it owns, so a palette
/// result can land on the right row or open the right sheet.
enum ScreenRequest: Equatable {
    case addMCPServer
    case pasteImport
    case selectMCPServer(String)
    case selectPlugin(String)
    case selectReceipt(String)
    case selectPreset(String)
    case selectProject(String)
    /// Open Apps and prepare the install plan, so a person who just asked for
    /// something lands on the one step that actually puts it in an app.
    case reviewChanges

    var section: AppSection {
        switch self {
        case .addMCPServer, .pasteImport, .selectMCPServer: .mcpServers
        case .selectPlugin: .plugins
        case .selectReceipt: .activity
        case .selectPreset: .presets
        case .selectProject: .projects
        case .reviewChanges: .syncCenter
        }
    }

    /// The requests a launch argument can name; the ones that carry an id have
    /// no launch form.
    static func named(_ value: String) -> ScreenRequest? {
        switch value.lowercased() {
        case "reviewchanges", "review-changes": .reviewChanges
        case "addmcpserver", "add-mcp-server": .addMCPServer
        case "pasteimport", "paste-import": .pasteImport
        default: nil
        }
    }

    /// The one row this request is about, when it is about a row at all.
    var itemID: String? {
        switch self {
        case .selectMCPServer(let id), .selectPlugin(let id), .selectReceipt(let id), .selectPreset(let id), .selectProject(let id): id
        case .addMCPServer, .pasteImport, .reviewChanges: nil
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

    /// What pointing at the result says it will do. A screen is gone to, an
    /// action says what it does, and anything else opens on its screen; one
    /// sentence shape for all of them read "Open Home in Go to".
    var help: String {
        switch outcome {
        case .navigate: "Go to \(title)"
        case .checkApps, .checkConnectionHealth, .reviewSync, .setUpThisMac: subtitle
        case .screenRequest(let request) where request.itemID == nil: subtitle
        case .openClient, .openSkill, .screenRequest: "Open \(title) in \(contextLabel)"
        }
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

    /// The rows the palette shows for `query`, best first: the matcher's
    /// ranking, with one exception. Set up this Mac… ranks above the other
    /// actions only so that typing "setup" reaches it before Check apps,
    /// which keeps "setup" among its old names. An empty palette still opens
    /// on Check apps, highlighted, so ↩ there reads this Mac's apps as it
    /// always has; Set up this Mac… waits after the other actions.
    static func results(_ items: [CommandPaletteItem], query: String) -> [CommandPaletteItem] {
        var ranked = CommandPaletteMatcher.rank(items, query: query)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let index = ranked.firstIndex(where: { $0.outcome == .setUpThisMac })
        else { return ranked }
        let setUp = ranked.remove(at: index)
        let actionIDs = Set(actions().map(\.id))
        let afterActions = ranked.lastIndex { actionIDs.contains($0.id) }.map { $0 + 1 } ?? 0
        ranked.insert(setUp, at: afterActions)
        return ranked
    }

    /// The palette is part of the window, so its entries are sentence case;
    /// the same commands keep title case in the menus. An entry that opens a
    /// sheet ends in an ellipsis, as its button on the screen does. A name an
    /// entry used to have stays among its keywords, so typing it still lands.
    private static func actions() -> [CommandPaletteItem] {
        [
            // The setup stage again, as the app menu, Apps and Settings name
            // it. Above the other actions, so "setup" reaches it before Check
            // apps, which keeps "setup" among its old names; an empty palette
            // still opens on Check apps (`results(_:query:)`).
            CommandPaletteItem(
                id: "action.setUpThisMac",
                title: ActionTitles.setUpThisMacCommand(.palette),
                subtitle: LaunchpadCopy.Reentry.paletteSubtitle,
                contextLabel: "Action",
                kind: nil,
                symbol: SetUpThisMacButton.symbol,
                keywords: ["setup", "set up", "onboarding", "agents", "run setup again", "first run"],
                priority: 110,
                outcome: .setUpThisMac),
            // The Apps toolbar's refresh, by its name and its symbol there.
            // "Setup" and the stethoscope are Checkup's, which this is not.
            CommandPaletteItem(
                id: "action.checkApps",
                title: ActionTitles.checkAppsCommand(.palette),
                subtitle: "Read this Mac again for what each app actually has",
                contextLabel: "Action",
                kind: nil,
                symbol: "arrow.clockwise",
                keywords: ["check setup", "setup", "doctor", "scan", "health", "refresh", "clients"],
                priority: 100,
                outcome: .checkApps),
            CommandPaletteItem(
                id: "action.reviewSync",
                title: ActionTitles.reviewChangesCommand(.palette),
                subtitle: "Prepare one plan for everything that is out of step",
                contextLabel: "Action",
                kind: nil,
                symbol: "arrow.triangle.2.circlepath",
                keywords: ["sync", "install", "plan", "reconcile", "apps", "review sync"],
                priority: 100,
                outcome: .reviewSync),
            CommandPaletteItem(
                id: "action.checkConnectionHealth",
                title: "Check connection health",
                subtitle: "Read each managed app's connections and see which need signing in",
                contextLabel: "Action",
                kind: nil,
                symbol: "waveform.path.ecg",
                keywords: ["health", "connection", "mcp", "connector", "auth", "login", "reauthenticate"],
                priority: 100,
                outcome: .checkConnectionHealth),
            CommandPaletteItem(
                id: "action.addServer",
                title: "Add connection…",
                subtitle: "Paste a definition to see what it describes",
                contextLabel: "Action",
                kind: .mcpServer,
                symbol: "plus",
                keywords: ["mcp", "new", "server", "add", "connection", "add mcp server"],
                priority: 100,
                outcome: .screenRequest(.addMCPServer)),
            CommandPaletteItem(
                id: "action.paste",
                title: "Paste to import…",
                subtitle: "Read an mcp add command, a JSON block, a server URL, or a SKILL.md",
                contextLabel: "Action",
                kind: nil,
                symbol: "doc.on.clipboard",
                keywords: ["paste", "clipboard", "json", "import", "skill.md"],
                priority: 100,
                outcome: .screenRequest(.pasteImport)),
        ]
    }

    /// Every screen, by its title. The name on its tab is a keyword, because a
    /// tab can be called something its screen's title is not: Activity's
    /// first tab reads "Receipts", and Settings' reads "General".
    private static func sections() -> [CommandPaletteItem] {
        AppSection.allCases.map { section in
            CommandPaletteItem(
                id: "section.\(section.id)",
                title: section.navigationTitle,
                subtitle: "Screen",
                contextLabel: "Go to",
                kind: nil,
                symbol: section.symbol,
                keywords: [section.rawValue, section.tabTitle, section.workspaceTitle ?? ""],
                priority: 60,
                outcome: .navigate(section))
        }
    }

    /// Only the apps this Mac manages. An app somebody has switched off is not a
    /// place a search result can send them.
    @MainActor
    private static func clients(for workspace: WorkspaceLaunch.Workspace) -> [CommandPaletteItem] {
        workspace.device.managedClients.map { client in
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
    /// Agent Tooling's own connection is no library entry and no screen lists
    /// it, so it has none.
    private static func rows(_ rows: [WorkspaceLibraryReadModelRow]) -> [CommandPaletteItem] {
        rows.filter { !$0.isOwnConnection }.compactMap { row in
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
                subtitle: "Preset · \(CountNoun("item").phrase(preset.memberArtifactIDs.count))",
                contextLabel: "Presets",
                kind: .collection,
                symbol: AppSection.presets.symbol,
                keywords: ["preset", "shelf", "collection"],
                priority: 30,
                outcome: .screenRequest(.selectPreset(preset.id.rawValue.uuidString.lowercased())))
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
                outcome: .screenRequest(.selectProject(project.id.rawValue.uuidString.lowercased())))
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
    /// Where the pointer last was, in window coordinates. Hover follows the
    /// pointer only when it moves: a row that scrolls under a still pointer
    /// (after an arrow key) must not take the highlight back.
    @State private var lastPointer: CGPoint?
    /// Set when the pointer moved the highlight, so the list does not scroll
    /// to a row that is already under it.
    @State private var highlightedByPointer = false
    @FocusState private var searchFocused: Bool

    private var results: [CommandPaletteItem] { CommandPaletteCatalog.results(items, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Hairline()
            resultList
            Hairline()
            hints
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        // The container declares the field as its default focus, and .onAppear
        // sets it again on the next run-loop turn. The palette floats in as an
        // overlay, where setting focus during the same turn the view appears was
        // unreliable — typed text landed in the page behind it — so the delayed
        // set is what actually lands the caret in the field.
        .defaultFocus($searchFocused, true)
        .onAppear {
            items = CommandPaletteCatalog.items(for: workspace)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                searchFocused = true
            }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onExitCommand(perform: onClose)
    }

    private var searchField: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: "magnifyingglass")
                .font(AgentFont.bodyMedium)
                .foregroundStyle(.secondary)
            TextField("Search apps, tools, presets, projects, and actions", text: $query)
                .textFieldStyle(.plain)
                .font(AgentFont.titleRegular)
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
        .padding(.horizontal, Space.xxl)
        .frame(height: Size.rowHeightTall)
    }

    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            VStack(spacing: Space.sm) {
                Text("Nothing matches \(query)")
                    .font(AgentFont.bodyMedium)
                Text("Search by name, or type an action such as \(ActionTitles.checkAppsCommand(.palette)).")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.xxs) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            Button {
                                highlighted = index
                                activateHighlighted()
                            } label: {
                                CommandPaletteRow(item: item, selected: index == highlighted)
                            }
                            .buttonStyle(.plain)
                            .onContinuousHover(coordinateSpace: .global) { phase in
                                guard case .active(let location) = phase else { return }
                                // The first report is where the pointer already
                                // was when the palette opened, not a movement.
                                defer { lastPointer = location }
                                guard let lastPointer, lastPointer != location, highlighted != index else { return }
                                highlightedByPointer = true
                                highlighted = index
                            }
                            .id(item.id)
                            .help(item.help)
                            .accessibilityLabel("\(item.title), \(item.subtitle)")
                            .accessibilityValue(index == highlighted ? "Selected" : "")
                        }
                    }
                    .padding(.vertical, Space.sm)
                    .padding(.horizontal, Space.md)
                }
                .onChange(of: highlighted) { _, index in
                    if highlightedByPointer {
                        highlightedByPointer = false
                        return
                    }
                    guard results.indices.contains(index) else { return }
                    withAnimation(AgentMotion.quick) { proxy.scrollTo(results[index].id, anchor: .center) }
                }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: Space.xl) {
            Label("Move", systemImage: "arrow.up.arrow.down")
            Label("Open", systemImage: "return")
            Label("Close", systemImage: "escape")
            Spacer()
            Text(CountNoun("result").phrase(results.count))
                .monospacedDigit()
        }
        .font(AgentFont.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.xl)
        .frame(height: Size.compactRowHeight)
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
        HStack(spacing: Space.lg) {
            if let client = item.client {
                ClientBrandIcon(client: client, size: Size.tileSmall)
                    .frame(width: Size.tile, height: Size.tile)
            } else if let kind = item.kind {
                KindTile(kind: kind, size: Size.tile)
            } else {
                Image(systemName: item.symbol)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(selected ? AgentTheme.onSelection : Color.secondary)
                    .frame(width: Size.tile, height: Size.tile)
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(item.title)
                    .font(AgentFont.bodyMedium)
                    .foregroundStyle(selected ? AgentTheme.onSelection : Color.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(AgentFont.caption)
                    .foregroundStyle(selected ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.lg)
            Text(item.contextLabel)
                .font(AgentFont.caption)
                .foregroundStyle(
                    selected
                        ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection)
                        : Color.secondary.opacity(Opacity.supporting)
                )
                .lineLimit(1)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: Size.rowHeight)
        .background {
            if selected {
                RoundedRectangle.control.fill(AgentTheme.selection)
            }
        }
        .contentShape(Rectangle())
    }
}
