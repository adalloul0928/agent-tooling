import AgentToolingCore
import SwiftUI

/// What activating a palette result does. The palette itself never changes
/// anything: it hands one of these back to the shell, which navigates or asks
/// the model for the same reviewed operation the screen's own button would.
enum CommandPaletteOutcome: Equatable {
    case navigate(AppSection)
    case openClient(ClientKind)
    case screenRequest(ScreenRequest)
    case openSkill(String)
    case openMarketplacePackage(String)
    case runDoctor
    case runSync
    case refreshMarketplace
}

/// A screen-specific request the shell hands to a screen it owns, so a palette
/// result can land on the right row or open the right sheet.
enum ScreenRequest: Equatable {
    case addMCPServer
    case pasteImport
    case selectMCPServer(String)
    case selectPlugin(String)
    case selectProfile(String)
    case selectMarketplaceSource(UUID)
    case selectAccount(UUID)
    case selectReceipt(UUID)

    var section: AppSection {
        switch self {
        case .addMCPServer, .pasteImport, .selectMCPServer: .mcpServers
        case .selectPlugin: .plugins
        case .selectProfile: .profiles
        case .selectMarketplaceSource: .marketplace
        case .selectAccount: .accounts
        case .selectReceipt: .activity
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
/// palette opens, from state that is already in memory.
enum CommandPaletteCatalog {
    static let maximumPackages = 120
    static let maximumReceipts = 25

    @MainActor
    static func items(for model: AppModel) -> [CommandPaletteItem] {
        actions(for: model) + sections() + clients(for: model) + skills(for: model) + servers(for: model) + plugins(for: model)
            + configurations(for: model) + sources(for: model) + packages(for: model) + accounts(for: model)
            + receipts(for: model)
    }

    @MainActor
    private static func actions(for model: AppModel) -> [CommandPaletteItem] {
        [
            CommandPaletteItem(
                id: "action.doctor",
                title: "Check Setup",
                subtitle: "Scan this Mac for what each app actually has",
                contextLabel: "Action",
                kind: nil,
                symbol: "stethoscope",
                keywords: ["doctor", "scan", "health", "check"],
                priority: 100,
                outcome: .runDoctor
            ),
            CommandPaletteItem(
                id: "action.sync",
                title: "Review Sync",
                subtitle: "Prepare one plan for everything that is out of step",
                contextLabel: "Action",
                kind: nil,
                symbol: "arrow.triangle.2.circlepath",
                keywords: ["sync", "install", "plan", "reconcile"],
                priority: 100,
                outcome: .runSync
            ),
            CommandPaletteItem(
                id: "action.addServer",
                title: "Add MCP server",
                subtitle: "Describe a server, then review its native commands",
                contextLabel: "Action",
                kind: .mcpServer,
                symbol: "plus",
                keywords: ["mcp", "new", "server"],
                priority: 100,
                outcome: .screenRequest(.addMCPServer)
            ),
            CommandPaletteItem(
                id: "action.paste",
                title: "Paste to import",
                subtitle: "Read an mcp add command, a JSON block, a URL, or a SKILL.md",
                contextLabel: "Action",
                kind: nil,
                symbol: "doc.on.clipboard",
                keywords: ["paste", "clipboard", "json", "import", "skill.md"],
                priority: 100,
                outcome: .screenRequest(.pasteImport)
            ),
            CommandPaletteItem(
                id: "action.newSkill",
                title: "New skill",
                subtitle: "Open Skills, where authoring starts",
                contextLabel: "Action",
                kind: .skill,
                symbol: "plus",
                keywords: ["create", "author", "skill"],
                priority: 100,
                outcome: .navigate(.skills)
            ),
            CommandPaletteItem(
                id: "action.refreshMarketplace",
                title: "Refresh Marketplace",
                subtitle: model.isRefreshingMarketplace ? "Already refreshing" : "Re-read every reviewed catalog and source",
                contextLabel: "Action",
                kind: nil,
                symbol: "arrow.clockwise",
                keywords: ["catalog", "sources", "updates", "refresh"],
                priority: 100,
                outcome: .refreshMarketplace
            ),
        ]
    }

    private static func sections() -> [CommandPaletteItem] {
        AppSection.allCases.map { section in
            CommandPaletteItem(
                id: "section.\(section.id)",
                title: section.rawValue,
                subtitle: "Screen",
                contextLabel: "Go to",
                kind: nil,
                symbol: section.symbol,
                keywords: [],
                priority: 60,
                outcome: .navigate(section)
            )
        }
    }

    @MainActor
    private static func clients(for model: AppModel) -> [CommandPaletteItem] {
        model.availableClients.map { client in
            CommandPaletteItem(
                id: "client.\(client.id)",
                title: client.rawValue,
                subtitle: "Show only this client's local state",
                contextLabel: "Clients",
                kind: nil,
                symbol: "desktopcomputer",
                keywords: ["client", "app", "local", "sync", "scope"],
                priority: 70,
                outcome: .openClient(client)
            )
        }
    }

    @MainActor
    private static func skills(for model: AppModel) -> [CommandPaletteItem] {
        model.visibleSkills.map { skill in
            CommandPaletteItem(
                id: "skill.\(skill.id)",
                title: skill.displayName,
                subtitle: "\(skill.owned ? "Managed skill" : "Discovered skill") · \(skill.scope)",
                contextLabel: "Skills",
                kind: .skill,
                symbol: "doc.text",
                keywords: [skill.id, skill.name] + skill.triggers,
                priority: 40,
                outcome: .openSkill(skill.id)
            )
        }
    }

    @MainActor
    private static func servers(for model: AppModel) -> [CommandPaletteItem] {
        model.visibleMCPServers.map { server in
            CommandPaletteItem(
                id: "mcp.\(server.id)",
                title: server.name,
                subtitle: "MCP server · \(server.transport.rawValue) · \(server.scope)",
                contextLabel: "Connections",
                kind: .mcpServer,
                symbol: "server.rack",
                keywords: [server.id, server.authentication],
                priority: 40,
                outcome: .screenRequest(.selectMCPServer(server.id))
            )
        }
    }

    @MainActor
    private static func plugins(for model: AppModel) -> [CommandPaletteItem] {
        model.visiblePlugins.map { plugin in
            CommandPaletteItem(
                id: "plugin.\(plugin.id)",
                title: plugin.name,
                subtitle: "Plugin · \(plugin.scope)",
                contextLabel: "Plugins",
                kind: .plugin,
                symbol: "puzzlepiece.extension",
                keywords: [plugin.id] + plugin.skills,
                priority: 40,
                outcome: .screenRequest(.selectPlugin(plugin.id))
            )
        }
    }

    @MainActor
    private static func configurations(for model: AppModel) -> [CommandPaletteItem] {
        model.profiles.map { profile in
            CommandPaletteItem(
                id: "profile.\(profile.id)",
                title: profile.name,
                subtitle: "Configuration · \(profile.scope.displayName)",
                contextLabel: "Configurations",
                kind: .profile,
                symbol: "slider.horizontal.3",
                keywords: [profile.id, profile.summary],
                priority: 40,
                outcome: .screenRequest(.selectProfile(profile.id))
            )
        }
    }

    @MainActor
    private static func sources(for model: AppModel) -> [CommandPaletteItem] {
        model.visibleSources.map { source in
            CommandPaletteItem(
                id: "source.\(source.id.uuidString)",
                title: source.name,
                subtitle: "Source · \(source.kind.displayName)",
                contextLabel: "Marketplace",
                kind: .source,
                symbol: "shippingbox",
                keywords: [source.location],
                priority: 30,
                outcome: .screenRequest(.selectMarketplaceSource(source.id))
            )
        }
    }

    @MainActor
    private static func packages(for model: AppModel) -> [CommandPaletteItem] {
        model.visibleMarketplacePackages.prefix(maximumPackages).map { package in
            CommandPaletteItem(
                id: "package.\(package.id)",
                title: package.name,
                subtitle: "Package · \(package.sourceName)",
                contextLabel: "Marketplace",
                kind: .plugin,
                symbol: "storefront",
                keywords: [package.id, package.publisher],
                priority: 20,
                outcome: .openMarketplacePackage(package.id)
            )
        }
    }

    @MainActor
    private static func accounts(for model: AppModel) -> [CommandPaletteItem] {
        model.visibleAccountSurfaces.map { surface in
            CommandPaletteItem(
                id: "account.\(surface.id.uuidString)",
                title: surface.name,
                subtitle: "Account check · \(surface.surface.displayName)",
                contextLabel: "Accounts",
                kind: .account,
                symbol: "person.badge.key",
                keywords: [surface.status.rawValue],
                priority: 20,
                outcome: .screenRequest(.selectAccount(surface.id))
            )
        }
    }

    @MainActor
    private static func receipts(for model: AppModel) -> [CommandPaletteItem] {
        model.visibleActivities.prefix(maximumReceipts).map { receipt in
            CommandPaletteItem(
                id: "receipt.\(receipt.id.uuidString)",
                title: receipt.displayTitle,
                subtitle: "Receipt · \(receipt.date.formatted(date: .abbreviated, time: .shortened))",
                contextLabel: "Activity",
                kind: .activity,
                symbol: "clock.arrow.circlepath",
                keywords: [receipt.detail],
                priority: 10,
                outcome: .screenRequest(.selectReceipt(receipt.id))
            )
        }
    }
}

/// One palette over every screen. Typing filters, the arrow keys move, Return
/// activates, Escape closes; nothing here writes.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
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
            items = CommandPaletteCatalog.items(for: model)
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
            TextField("Search clients, tools, sources, receipts, and actions", text: $query)
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
