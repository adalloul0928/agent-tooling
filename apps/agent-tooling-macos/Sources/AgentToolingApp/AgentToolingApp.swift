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
                } else if needsFirstLaunchChoice {
                    FirstLaunchChooser(
                        start: { Task { await load(createIfNeeded: true) } },
                        join: { remote, branch in Task { await join(remote: remote, branch: branch) } },
                        isBusy: isJoining, error: joinError)
                } else {
                    // A first run scans the installed clients, which takes a
                    // moment and is worth saying rather than showing an empty
                    // window somebody would take for a broken one.
                    ProgressView("Opening your workspace…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: WindowSize.minimum.width, minHeight: WindowSize.minimum.height)
            .containerBackground(.clear, for: .window)
            .background(WindowConfigurator())
            .preferredColorScheme(colorScheme)
            .task { await load() }
            .onOpenURL { url in
                guard navigation.open(url: url) else { return }
                bringMainWindowForward()
            }
        }
        .defaultSize(WindowSize.standard)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                // The same review the menu-bar item and the palette open, under
                // the same name; a menu title-cases it.
                Button(ActionTitles.reviewChangesCommand(.menu)) {
                    guard workspace != nil else { return }
                    // Preparing is not applying. This opens Apps with a plan on
                    // it; writing anything is still a decision made there.
                    navigation.showAllClients()
                    navigation.openScreenRequest(.reviewChanges)
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
                Button("Try Again") { Task { await load() } }
                Divider()
                Button("Quit Agent Tooling") { NSApp.terminate(nil) }
            }
        }

        Settings {
            // The system Settings window keeps the grouped-form idiom it is
            // expected to have; the in-app Settings screen shows the same
            // binding as one row in its own card.
            Form {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
            }
            .formStyle(.grouped)
            .frame(width: WindowSize.settingsWidth)
        }
    }

    /// Opens the workspace, creating one on a first run.
    ///
    /// Failure is shown rather than swallowed: an app that opens to an empty
    /// library after failing to read one looks exactly like an app whose
    /// library is empty.
    /// A Mac with no workspace yet is asked whether this is its first Mac or
    /// its second, instead of silently becoming a workspace of its own.
    @State private var needsFirstLaunchChoice = false
    @State private var isJoining = false
    @State private var joinError: String?

    private func load(createIfNeeded: Bool = false) async {
        guard workspace == nil else { return }
        let context = LaunchContext.current
        if !createIfNeeded, !WorkspaceLaunch.hasWorkspace(supportRoot: context.workspaceRoot) {
            needsFirstLaunchChoice = true
            return
        }
        needsFirstLaunchChoice = false
        do {
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

    private func join(remote: String, branch: String) async {
        guard workspace == nil, !isJoining else { return }
        isJoining = true
        joinError = nil
        defer { isJoining = false }
        let context = LaunchContext.current
        do {
            workspace = try await WorkspaceLaunch.join(
                remote: remote, branch: branch.isEmpty ? "main" : branch,
                supportRoot: context.workspaceRoot,
                homeRoot: context.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser)
            needsFirstLaunchChoice = false
            startupError = nil
        } catch let error as WorkspaceJoinError {
            joinError = error.localizedDescription
        } catch GitWorkspaceTransportError.invalidRemote {
            joinError = WorkspaceJoinError.invalidRemote.localizedDescription
        } catch {
            joinError = "That repository could not be read from this Mac. Check the address and your access. (\(error.localizedDescription))"
        }
    }

    private func bringMainWindowForward() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The identifier WindowConfigurationView (Theme.swift) gives the main
        // window when it appears; the scene id alone is not what AppKit sees.
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
/// what is out of step. Nothing here writes to a client. Its items are menu
/// items, so they title-case the way the system's own do, busy or not.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let workspace: WorkspaceLaunch.Workspace
    let navigation: AppNavigationState

    var body: some View {
        Button("Open Agent Tooling") { open() }
        Divider()
        Button(workspace.device.isChecking ? "Checking Setup…" : "Check Setup") {
            Task { await workspace.device.refresh() }
        }
        .disabled(workspace.device.isChecking)
        Button(workspace.deployment.isBusy ? "Preparing Changes…" : ActionTitles.reviewChangesCommand(.menu)) {
            open()
            navigation.showAllClients()
            navigation.openScreenRequest(.reviewChanges)
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
        // One row in the card it sits in, in the grammar of the other Settings
        // rows. The card is titled "Appearance", so the row names the choice
        // rather than printing the word a second time. A grouped Form here
        // drew its own inset card and gray ground inside the section's card —
        // three nested surfaces for one picker.
        InfoRow("Light or dark", detail: "System follows macOS.") {
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
        } trailing: {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Shown when the workspace could not be opened at all.
/// The first thing a Mac with no workspace sees: is this your first Mac, or
/// does another Mac already have your library?
struct FirstLaunchChooser: View {
    let start: () -> Void
    let join: (String, String) -> Void
    let isBusy: Bool
    let error: String?
    @State private var remote = ""
    @State private var branch = "main"
    @State private var showsJoin = false

    var body: some View {
        VStack(spacing: Space.xxl) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: Size.heroSymbolLarge))
                .foregroundStyle(.secondary)
            VStack(spacing: Space.sm) {
                Text("Welcome to Agent Tooling").font(AgentFont.pageTitle)
                Text("Is this your first Mac, or does another Mac already have your library?")
                    .font(AgentFont.body).foregroundStyle(.secondary).multilineTextAlignment(.center).wrapsLines()
            }
            if showsJoin {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Paste the repository address the other Mac is connected to (Settings › Sync on that Mac).")
                        .font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
                    TextField("git@github.com:you/agent-tooling-workspace.git", text: $remote)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Branch").font(AgentFont.caption).foregroundStyle(.secondary)
                        TextField("main", text: $branch).textFieldStyle(.roundedBorder).frame(width: Size.fieldNarrow)
                    }
                    if let error { AttentionBanner(title: "Couldn’t join", message: error) }
                    HStack {
                        Button("Back") { showsJoin = false }.secondaryActionStyle().disabled(isBusy)
                        Spacer()
                        Button(isBusy ? "Joining…" : "Join") { join(remote, branch) }
                            .primaryActionStyle().disabled(isBusy || remote.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(Space.xl)
                .frame(width: Size.firstLaunchFormWidth)
                .standardPanel()
            } else {
                HStack(spacing: Space.lg) {
                    Button("Start here", systemImage: "sparkles") { start() }.primaryActionStyle().keyboardShortcut(.defaultAction)
                    Button("Join another Mac’s workspace", systemImage: "arrow.triangle.2.circlepath") { showsJoin = true }
                        .secondaryActionStyle()
                }
                Text("Starting here scans this Mac’s apps and builds a library from them. Joining takes the library another Mac already shares, and this Mac becomes one of its Macs.")
                    .font(AgentFont.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).wrapsLines()
                    .frame(maxWidth: Size.firstLaunchFormWidth)
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
    }
}

struct StartupFailureView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Agent Tooling could not open your workspace", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry).primaryActionStyle()
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
