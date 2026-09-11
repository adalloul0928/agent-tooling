import AgentToolingCore
import SwiftUI

@main
struct AgentToolingApplication: App {
    @State private var workspace: WorkspaceLaunch.Workspace?
    @State private var startupError: String?
    /// Held here rather than in the window so a menu-bar item, an app command
    /// and a link all reach the same navigation the sidebar reads.
    @State private var navigation = AppNavigationState()
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false

    var body: some Scene {
        Window("Agent Tooling", id: "main") {
            Group {
                if let workspace {
                    AppShellView(
                        workspace: workspace,
                        initialSection: LaunchContext.current.request?.section ?? LaunchContext.current.section ?? .overview,
                        navigation: navigation)
                } else if let startupError {
                    StartupFailureView(message: startupError) { Task { await load() } }
                } else {
                    // A first run scans the installed clients, which takes a
                    // moment and is worth saying rather than showing an empty
                    // window somebody would take for a broken one.
                    ProgressView("Opening your workspace…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 1_180, minHeight: 760)
            .containerBackground(.clear, for: .window)
            .background(WindowConfigurator())
            .preferredColorScheme(colorScheme)
            .task { await load() }
            .onOpenURL { url in
                guard navigation.open(url: url) else { return }
                bringMainWindowForward()
            }
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Agent Tooling") {
                    guard let workspace else { return }
                    // Preparing is not applying. This opens Apps with a plan on
                    // it; writing anything is still a decision made there.
                    navigation.showAllClients()
                    Task { await workspace.deployment.prepare() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace?.deployment.isBusy != false)

                Button("Check Setup") {
                    guard let workspace else { return }
                    Task { await workspace.device.refresh() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace?.device.isChecking != false)
            }
            CommandGroup(after: .sidebar) {
                Button(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    sidebarCollapsed.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        MenuBarExtra("Agent Tooling", systemImage: "slider.horizontal.3", isInserted: $showMenuBarItem) {
            if let workspace {
                MenuBarContent(workspace: workspace, navigation: navigation)
            } else {
                Text("Agent Tooling could not open your workspace")
                Button("Try again") { Task { await load() } }
                Divider()
                Button("Quit Agent Tooling") { NSApp.terminate(nil) }
            }
        }

        Settings { AppearanceSettingsView(appearance: $appearance) }
    }

    /// Opens the workspace, creating one on a first run.
    ///
    /// Failure is shown rather than swallowed: an app that opens to an empty
    /// library after failing to read one looks exactly like an app whose
    /// library is empty.
    private func load() async {
        guard workspace == nil else { return }
        do {
            let context = LaunchContext.current
            workspace = try await WorkspaceLaunch.open(
                supportRoot: context.workspaceRoot,
                homeRoot: context.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser)
            startupError = nil
            // A launch that names a screen request arrives with it already asked
            // for, so the section it opens on consumes it as it would from the palette.
            if let request = context.request { navigation.openScreenRequest(request) }
        } catch {
            workspace = nil
            startupError = error.localizedDescription
        }
    }

    private func bringMainWindowForward() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "agent-tooling-main" })
        else { return }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }
}

/// The menu-bar item: open the window, read this Mac again, or go and look at
/// what is out of step. Nothing here writes to a client.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let workspace: WorkspaceLaunch.Workspace
    let navigation: AppNavigationState

    var body: some View {
        Button("Open Agent Tooling") { open() }
        Divider()
        Button(workspace.device.isChecking ? "Checking setup…" : "Check Setup") {
            Task { await workspace.device.refresh() }
        }
        .disabled(workspace.device.isChecking)
        Button(workspace.deployment.isBusy ? "Preparing changes…" : "Review sync") {
            open()
            navigation.showAllClients()
            Task { await workspace.deployment.prepare() }
        }
        .disabled(workspace.deployment.isBusy)
        Divider()
        Button("Quit Agent Tooling") { NSApp.terminate(nil) }
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppearanceSettingsView: View {
    @Binding var appearance: String

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding(20)
    }
}

/// Shown when the workspace could not be opened at all.
struct StartupFailureView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Agent Tooling could not open your workspace", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry).buttonStyle(.borderedProminent)
        }
    }
}

/// Where this launch was told to look, and what it was told to open. Used by
/// tests and packaged pilots to point the app at a scratch folder; absent in
/// ordinary use.
struct LaunchContext {
    var workspaceRoot: URL?
    var homeRoot: URL?
    /// The screen this launch opens on. Absent means Home.
    var section: AppSection?
    /// A screen request to open on, such as `reviewChanges`; its section wins.
    var request: ScreenRequest?

    static var current: LaunchContext {
        var context = LaunchContext()
        var arguments = ProcessInfo.processInfo.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--workspace":
                context.workspaceRoot = arguments.next().map { URL(fileURLWithPath: $0).standardizedFileURL }
            case "--home":
                context.homeRoot = arguments.next().map { URL(fileURLWithPath: $0).standardizedFileURL }
            case "--section":
                context.section = arguments.next().flatMap(AppSection.named)
            case "--request":
                context.request = arguments.next().flatMap(ScreenRequest.named)
            default: continue
            }
        }
        return context
    }
}

extension AppSection {
    /// Accepts either how a section is written down — its durable raw value —
    /// or how it is written in code, because both appear in scripts and neither
    /// is more correct than the other. An unrecognised name is no answer rather
    /// than a wrong one, so a typo opens Home instead of a random screen.
    static func named(_ name: String) -> AppSection? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return allCases.first {
            $0.rawValue.lowercased() == wanted || String(describing: $0).lowercased() == wanted
        }
    }
}
