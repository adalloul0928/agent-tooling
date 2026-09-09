import AgentToolingCore
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Native render coverage uses an isolated home and store. It must never
/// bootstrap or operate on the person's actual client installations.
@Suite("Workspace render coverage")
@MainActor
struct WorkspaceRenderTests {
    @Test func destinationsRenderInBothAppearances() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesID = "workspace-render-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: preferencesID))
        defer { preferences.removePersistentDomain(forName: preferencesID) }
        let store = try WorkspaceStore(rootURL: root.appending(path: "store"))
        let clients = [ClientState(client: .codex, state: .healthy, detail: "Found locally", isInstalled: true)]
        let titles = ["Review a pull request", "Prepare a release", "Research a topic", "Plan your day"]
        let skills = titles.enumerated().map { index, title in
            Skill(
                id: "preview-\(index)", name: "preview-\(index)", displayName: title,
                summary: "A reusable workflow with instructions, references, and app availability.",
                bundle: "Developer Workflows", scope: "User", owned: false,
                triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: clients, validationCount: 0)
        }
        let plugin = Plugin(
            id: "github@openai-curated-remote", name: "GitHub",
            summary: "Review, test, and ship your projects with reusable workflows.",
            source: "Example source", scope: "User", revision: "1.0", skills: skills.map(\.id),
            profiles: [], clients: clients, installed: true)
        let server = MCPServer(
            id: "reference", name: "Documentation", summary: "Read project documentation.",
            endpoint: "https://example.invalid/mcp", transport: .http,
            authentication: "Managed in the app", scope: "User", clients: clients)
        let packages = titles.enumerated().map { index, title in
            MarketplacePackage(
                id: "preview-package-\(index)", name: title, publisher: "Example publisher",
                summary: "A useful collection of skills and tools for your everyday work.",
                sourceName: "Preview catalog", components: [.skill, .plugin],
                supportedClients: [.claude, .codex], location: "https://example.invalid/package")
        }
        try store.save(
            WorkspaceSnapshot(
                skills: skills, mcpServers: [server], plugins: [plugin],
                marketplacePackages: packages), for: "workspace.snapshot")
        try store.saveInsightsReport(
            InsightsReport(
                windowStart: Date().addingTimeInterval(-604800), coverage: [], skillUsage: [], qualityFindings: [],
                recommendations: skills.enumerated().map { index, skill in
                    ToolRecommendation(
                        id: "recommendation-\(index)", kind: .useExistingSkill,
                        title: "Use \(skill.displayName)", summary: skill.summary,
                        rationale: "Recent work overlaps with this installed skill.", confidence: .medium,
                        supportingConversationCount: 3, skillID: skill.id)
                },
                conversationsScanned: 8, itemsInspected: 64))
        let model = try AppModel(store: store, homeURL: root.appending(path: "home"))
        let screens =
            AppSection.allCases.map { ($0, false) }
            + [AppSection.plugins, .mcpServers, .skills, .marketplace].map { ($0, true) }
        for scheme in [ColorScheme.dark, .light] {
            for width in [1180.0, 1660.0] {
                var marketplaceBrowserSplitCount: Int?
                for (section, details) in screens {
                    let navigation = AppNavigationState()
                    if details && section == .skills { navigation.open(.skill(skills[0].id)) }
                    if details && section == .marketplace { navigation.openMarketplacePackage(packages[0].id) }
                    let content = NavigationSplitView {
                        SidebarView(selection: .constant(section), isCollapsed: .constant(false))
                            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
                    } detail: {
                        destination(section, details: details)
                            .environment(\.workspaceSelection, section)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AgentTheme.contentBackground, ignoresSafeAreaEdges: [.top, .bottom, .trailing])
                    }
                    .navigationSplitViewStyle(.balanced)
                    .environment(model)
                    .environment(navigation)
                    .defaultAppStorage(preferences)
                    .environment(\.colorScheme, scheme)
                    .groupBoxStyle(ControlGroupBoxStyle())
                    .frame(width: width, height: 850)
                    let view = NSHostingView(rootView: content)
                    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 850)
                    // Native tables need a window and a layout turn to populate.
                    // This window is never ordered on screen.
                    let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = view
                    defer { window.close() }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                    view.layoutSubtreeIfNeeded()
                    if section == .plugins || section == .mcpServers {
                        #expect(nativeTables(in: view).contains { $0.numberOfRows > 0 })
                    }
                    if section == .marketplace {
                        let splitCount = nativeSplitViews(in: view).count
                        if details {
                            let browserSplitCount = try #require(marketplaceBrowserSplitCount)
                            // The inspector adds a real browser/detail split;
                            // a narrower gallery alone must not pass this case.
                            #expect(splitCount == browserSplitCount + 1)
                        } else {
                            marketplaceBrowserSplitCount = splitCount
                        }
                    }
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    #expect(abs(bitmap.size.width - width) < 1)
                    #expect(abs(bitmap.size.height - 850) < 1)
                    #expect(model.pendingPlan == nil)
                    if let folder = ProcessInfo.processInfo.environment["WORKSPACE_LAYOUT_CAPTURE"],
                        let png = bitmap.representation(using: .png, properties: [:])
                    {
                        let name =
                            "\(section.rawValue.lowercased())\(details ? "-detail" : "")-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"
                        try png.write(to: URL(fileURLWithPath: folder).appending(path: name))
                    }
                }
            }
        }
    }

    private func nativeTables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { nativeTables(in: $0) }
    }

    private func nativeSplitViews(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { nativeSplitViews(in: $0) }
    }

    @ViewBuilder private func destination(_ section: AppSection, details: Bool) -> some View {
        switch section {
        case .overview: OverviewView(navigate: { _ in }, onOpenPlugin: { _ in })
        case .marketplace: MarketplaceView()
        case .skills: SkillsView()
        case .plugins: PluginsView(navigate: { _ in }, request: .constant(details ? .selectPlugin("github@openai-curated-remote") : nil))
        case .mcpServers: MCPServersView(request: .constant(details ? .selectMCPServer("reference") : nil))
        case .collections: CollectionsView()
        case .profiles: ProfilesView()
        case .syncCenter: SyncCenterView()
        case .accounts: AccountsView()
        case .insights: InsightsView()
        case .activity: ActivityView()
        case .projects: ProjectsView()
        case .settings: SettingsView()
        }
    }
}
