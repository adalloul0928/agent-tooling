import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

private struct PerformanceNoCommandRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        Issue.record("The isolated performance fixture must not invoke client commands.")
        return CommandOutput(status: 127, standardOutput: "", standardError: "No commands allowed")
    }
}

/// Opt in with AGENT_TOOLING_BENCHMARK=1 and run only this suite, without other
/// tests or builds in parallel. Compare the same configuration and machine.
/// Settling metrics include an intentional 60 ms run-loop window and are not
/// response latency. Synchronous layout/drawing is reported separately.
/// Set AGENT_TOOLING_BENCHMARK_SKILLS=5000 for the large-inventory workload;
/// the default remains 500 so earlier measurements remain comparable.
@Suite("Workspace performance", .serialized, .enabled(if: ProcessInfo.processInfo.environment["AGENT_TOOLING_BENCHMARK"] == "1"))
@MainActor
struct WorkspacePerformanceTests {
    @Test func representativeInventory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-performance-\(UUID())", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesID = "workspace-performance-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: preferencesID))
        defer { preferences.removePersistentDomain(forName: preferencesID) }
        preferences.set(true, forKey: "skills.groupingMigration")
        let ownership = Dictionary(uniqueKeysWithValues: (0..<100).map { ("source:benchmark-plugin-\($0)", "thirdParty") })
        preferences.set(String(decoding: try JSONEncoder().encode(ownership), as: UTF8.self), forKey: "skills.sourceOwnership")
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let snapshot = fixture(home: home)
        let store = try WorkspaceStore(rootURL: root.appending(path: "store", directoryHint: .isDirectory))
        try store.saveWorkspaceSnapshot(snapshot)
        var metrics: [String: [Double]] = [:]

        for _ in 0..<6 {
            metrics["snapshot_validate_ms", default: []].append(try elapsed { try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState) })
            metrics["snapshot_encode_ms", default: []].append(try elapsed { _ = try AgentToolingCoding.encoder().encode(snapshot) })
            // This includes per-entity encoding, the compatibility snapshot, and
            // the real temporary SQLite transaction; validation is separate.
            metrics["snapshot_store_ms", default: []].append(try elapsed { try store.saveWorkspaceSnapshot(snapshot) })
            metrics["model_load_ms", default: []].append(try elapsed {
                _ = try AppModel(store: store, runner: PerformanceNoCommandRunner(), homeURL: home)
            })
        }
        let model = try AppModel(store: store, runner: PerformanceNoCommandRunner(), homeURL: home)
        let navigation = AppNavigationState()
        for section in [AppSection.skills, .plugins, .mcpServers] {
            for iteration in 0..<6 {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                var host: NSHostingView<AnyView>!
                let mount = elapsed {
                    host = NSHostingView(rootView: content(section).environment(model).environment(navigation)
                        .defaultAppStorage(preferences).environment(\.colorScheme, .dark)
                        .groupBoxStyle(ControlGroupBoxStyle()).frame(width: 1180, height: 850).erased())
                    host.frame = window.contentView!.bounds
                    host.appearance = NSAppearance(named: .darkAqua)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                }
                metrics["\(section.rawValue)_mount_sync_ms", default: []].append(mount)
                metrics["\(section.rawValue)_settle60_ms", default: []].append(elapsed {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                    host.layoutSubtreeIfNeeded()
                })
                metrics["\(section.rawValue)_layout_draw_ms", default: []].append(try elapsed { try draw(host) })
                if section != .skills {
                    #expect(nativeTables(host).contains { $0.numberOfRows == 100 })
                }
                metrics["\(section.rawValue)_update_settle60_ms", default: []].append(elapsed {
                    switch section {
                    case .skills: model.skills[0].summary = "Updated fixture summary \(iteration)"
                    case .plugins: model.plugins[0].summary = "Updated fixture summary \(iteration)"
                    case .mcpServers: model.mcpServers[0].summary = "Updated fixture summary \(iteration)"
                    default: break
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                    host.layoutSubtreeIfNeeded()
                })
                metrics["\(section.rawValue)_update_layout_draw_ms", default: []].append(try elapsed { try draw(host) })
                #expect(model.pendingPlan == nil)
                window.contentView = nil
            }
        }
        let label = ProcessInfo.processInfo.environment["AGENT_TOOLING_BENCHMARK_LABEL"] ?? "unspecified"
        print("BENCHMARK label=\(label) skills=\(skillCount) plugins=100 mcp=100 observations=3 collections=25 tags=\(skillCount)")
        for key in metrics.keys.sorted() {
            let values = try #require(metrics[key])
            let warm = Array(values.dropFirst()).sorted()
            print("BENCHMARK \(key) first=\(format(values[0])) median=\(format(warm[warm.count / 2])) max=\(format(warm.last!)) warm_samples=\(warm.count)")
        }
    }

    /// A separate workload preserves the inventory baseline while exercising
    /// per-plugin update matching against a substantial marketplace catalog.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_TOOLING_CATALOG_BENCHMARK"] == "1"))
    func catalogHeavyPlugins() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "catalog-performance-\(UUID())", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesID = "catalog-performance-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: preferencesID))
        defer { preferences.removePersistentDomain(forName: preferencesID) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        var snapshot = fixture(home: home)
        snapshot.marketplacePackages = (0..<500).map { index in
            MarketplacePackage(
                id: "claude:benchmark-plugin-\(index)", name: "Workflow plugin \(index)", publisher: "Fixture",
                summary: "Reusable workflows for local projects.", sourceName: "Fixture catalog", revision: "fixture",
                components: [.plugin, .skill], supportedClients: [.claude, .codex],
                location: home.appending(path: "plugins/plugin-\(index)").path)
        }
        let store = try WorkspaceStore(rootURL: root.appending(path: "store", directoryHint: .isDirectory))
        try store.saveWorkspaceSnapshot(snapshot)
        let model = try AppModel(store: store, runner: PerformanceNoCommandRunner(), homeURL: home)
        var metrics: [String: [Double]] = [:]
        for iteration in 0..<6 {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            var host: NSHostingView<AnyView>!
            metrics["catalog_plugins_mount_sync_ms", default: []].append(elapsed {
                host = NSHostingView(rootView: PluginsView(navigate: { _ in }).environment(model)
                    .defaultAppStorage(preferences)
                    .environment(\.colorScheme, .dark).groupBoxStyle(ControlGroupBoxStyle())
                    .frame(width: 1180, height: 850).erased())
                host.frame = window.contentView!.bounds
                host.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
            })
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            metrics["catalog_plugins_layout_draw_ms", default: []].append(try elapsed { try draw(host) })
            #expect(nativeTables(host).contains { $0.numberOfRows == 100 })
            metrics["catalog_plugins_update_settle60_ms", default: []].append(elapsed {
                model.plugins[0].summary = "Updated fixture catalog plugin \(iteration)"
                RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                host.layoutSubtreeIfNeeded()
            })
            metrics["catalog_plugins_update_layout_draw_ms", default: []].append(try elapsed { try draw(host) })
            #expect(model.pendingPlan == nil)
            window.contentView = nil
        }
        let label = ProcessInfo.processInfo.environment["AGENT_TOOLING_BENCHMARK_LABEL"] ?? "unspecified"
        print("BENCHMARK label=\(label) plugins=100 catalog_packages=500")
        for key in metrics.keys.sorted() {
            let values = try #require(metrics[key])
            let warm = Array(values.dropFirst()).sorted()
            print("BENCHMARK \(key) first=\(format(values[0])) median=\(format(warm[warm.count / 2])) max=\(format(warm.last!)) warm_samples=\(warm.count)")
        }
    }

    private var skillCount: Int {
        ProcessInfo.processInfo.environment["AGENT_TOOLING_BENCHMARK_SKILLS"] == "5000" ? 5_000 : 500
    }

    private func fixture(home: URL) -> WorkspaceSnapshot {
        let clients = ClientKind.allCases.map { ClientState(client: $0, state: .healthy, detail: "Fixture installed", isInstalled: true) }
        // Unqualified synthetic IDs prevent the existing connector scanner from
        // probing its default real-home marketplace cache. Sources are isolated.
        let skillsPerPlugin = skillCount / 100
        let skillsPerCollection = skillCount / 25
        let skills = (0..<skillCount).map { index in
            Skill(
                id: "benchmark-skill-\(index)", name: "benchmark-skill-\(index)", displayName: "Review workflow \(index)",
                summary: "Review a change using its instructions and references, then describe the result.",
                bundle: "benchmark-plugin-\(index / skillsPerPlugin)", scope: "User", owned: false, triggers: [], negativeTrigger: "",
                files: ["SKILL.md"], clients: clients, validationCount: 0)
        }
        let plugins = (0..<100).map { index in
            Plugin(
                id: "benchmark-plugin-\(index)", name: "Workflow plugin \(index)", summary: "Reusable workflows for local projects.",
                source: home.appending(path: "plugins/plugin-\(index)").path, scope: "User", revision: "fixture",
                skills: Array(skills[(index * skillsPerPlugin)..<((index + 1) * skillsPerPlugin)]).map(\.id), profiles: [], clients: clients, installed: true)
        }
        let servers = (0..<100).map { index in
            MCPServer(
                id: "benchmark-server-\(index)", name: "Documentation service \(index)", summary: "Read documentation for local workflows.",
                endpoint: "https://example.invalid/service-\(index)", transport: .http, authentication: "None", scope: "User", clients: clients)
        }
        let observations = [TargetSurface.claudeCode, .codexCLI, .geminiCLI].map { surface in
            TargetObservation(
                surface: surface, installed: true, commandAvailable: false,
                discoveredSkills: skills.map(\.id), discoveredPlugins: plugins.map(\.id), discoveredMCPServers: servers.map(\.id),
                skillMetadata: Dictionary(uniqueKeysWithValues: skills.map { skill in
                    (skill.id, ObservedSkillMetadata(path: home.appending(path: "skills/\(skill.id)").path,
                        source: "Fixture", providerPluginID: skill.bundle))
                }),
                capabilities: TargetCapabilities(
                    supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
                    supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                    requiresRestart: false, supportsMachineReadableOutput: false))
        }
        let collections = (0..<25).map { index in
            ToolingCollection(id: "benchmark-collection-\(index)", name: "Collection \(index)", items:
                Array(skills[(index * skillsPerCollection)..<((index + 1) * skillsPerCollection)]).map { ToolingItemReference(kind: .skill, identifier: $0.id) })
        }
        let assignments = skills.map { TagAssignment(item: ToolingItemReference(kind: .skill, identifier: $0.id), tags: ["Review", "Development"]) }
        return WorkspaceSnapshot(skills: skills, mcpServers: servers, plugins: plugins, targetObservations: observations,
            collections: collections, tagAssignments: assignments)
    }

    private func elapsed(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    private func draw(_ host: NSView) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
    }

    private func format(_ milliseconds: Double) -> String { String(format: "%.3f", milliseconds) }

    private func nativeTables(_ view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(nativeTables)
    }

    @ViewBuilder private func content(_ section: AppSection) -> some View {
        switch section {
        case .skills: SkillsView()
        case .plugins: PluginsView(navigate: { _ in })
        case .mcpServers: DirectMCPServersView()
        default: EmptyView()
        }
    }
}

private extension View {
    func erased() -> AnyView { AnyView(self) }
}
