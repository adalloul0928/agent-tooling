import AgentToolingCore
import SwiftUI

// MARK: - The main window

/// Hosts the main window's launch phases. While setup owns launch, redirects to
/// the stage and closes itself. Registers `openWindow` for Dock and link reopens,
/// and consumes hand-off navigation and launch hints once per shell.
struct MainWindowRoot: View {
    let launch: AppLaunchState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    /// The section and hints this window's shell opened with.
    @State private var start: AppLaunchState.ShellStart?

    var body: some View {
        content
            .frame(minWidth: WindowSize.minimum.width, minHeight: WindowSize.minimum.height)
            .containerBackground(.clear, for: .window)
            // A scratch run (`--defaults-suite`) keeps AppKit's own frame and
            // divider autosave out of the app's defaults, which the suite
            // does not cover.
            .background(WindowConfigurator(role: .main, savesFrames: launch.context.defaultsSuite == nil))
            .onAppear { launch.mainAppeared(openWindow: WindowOpener(openWindow)) }
            .onChange(of: launch.ownsLaunch, initial: true) { _, owns in
                guard owns else { return }
                launch.presentStage(launch.pendingEntry, openWindow: WindowOpener(openWindow))
                // After this turn, so the window closes once it has appeared.
                Task { @MainActor in dismiss() }
            }
            .onOpenURL { launch.openLink($0) }
    }

    @ViewBuilder private var content: some View {
        switch launch.phase {
        case .ready:
            if let workspace = launch.readyWorkspace {
                shell(workspace)
            }
        case .failed(let message):
            StartupFailureView(message: message) {
                Task { await launch.tryAgain() }
            }
        case .opening:
            ProgressView(LaunchpadCopy.Welcome.openingWorkspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .setup, .unreadable:
            Color.clear
        }
    }

    private func shell(_ workspace: WorkspaceLaunch.Workspace) -> some View {
        let start = start ?? launch.shellStart
        return AppShellView(workspace: workspace, initialSection: start.section, navigation: launch.navigation)
            .environment(\.openSetup) { entry in
                launch.presentStage(entry, openWindow: WindowOpener(openWindow))
            }
            .environment(\.stagePresented, launch.stagePresentedOverShell)
            .environment(\.shellLaunchHints, start.hints)
            .onAppear {
                if self.start == nil { self.start = start }
                launch.shellAppeared()
            }
            .onDisappear { launch.shellDisappeared() }
    }
}

// MARK: - The menu-bar item

/// One item of the menu-bar item. Until the hand-off it offers only Show
/// Setup and Quit Agent Tooling; while the library opens, a quiet line and
/// Quit; when it could not open, what went wrong, Try Again and Quit.
enum MenuBarItem: Equatable, Sendable {
    case showSetup
    /// "Opening your workspace…", disabled.
    case opening
    /// "Agent Tooling could not open your workspace", as text.
    case couldNotOpen
    case tryAgain
    case openAgentTooling
    case checkApps(checking: Bool)
    case reviewChanges(preparing: Bool)
    case quit
    case divider

    /// The item's title. Menu items title-case, the way the system's own do;
    /// the two lines that are not commands read as the window says them.
    var title: String {
        switch self {
        case .showSetup: ActionTitles.showSetup
        case .opening: LaunchpadCopy.Welcome.openingWorkspace
        case .couldNotOpen: LaunchpadCopy.Welcome.couldNotOpenWorkspace
        case .tryAgain: ActionTitles.tryAgainMenu
        case .openAgentTooling: ActionTitles.openAgentTooling
        case .checkApps(let checking): checking ? ActionTitles.checkingAppsMenu : ActionTitles.checkAppsCommand(.menu)
        case .reviewChanges(let preparing):
            preparing ? ActionTitles.preparingChangesMenu : ActionTitles.reviewChangesCommand(.menu)
        case .quit: ActionTitles.quitAgentTooling
        case .divider: ""
        }
    }

    /// Whether the item can be chosen now.
    var isEnabled: Bool {
        switch self {
        case .opening, .couldNotOpen, .divider: false
        case .checkApps(let checking): !checking
        case .reviewChanges(let preparing): !preparing
        case .showSetup, .tryAgain, .openAgentTooling, .quit: true
        }
    }
}

/// The menu-bar item's menu, from the launch's items for its phase. Nothing
/// here writes to an app. Open Agent Tooling and Review Changes… hand the
/// launch the menu's own `openWindow`, so the main window opens even when the
/// person has closed it.
struct MenuBarRoot: View {
    let launch: AppLaunchState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(launch.menuBarItems.enumerated()), id: \.offset) { _, item in
            switch item {
            case .divider:
                Divider()
            case .couldNotOpen:
                Text(item.title)
            default:
                Button(item.title) { choose(item) }
                    .disabled(!item.isEnabled)
            }
        }
    }

    private func choose(_ item: MenuBarItem) {
        switch item {
        case .showSetup:
            launch.presentStage(launch.pendingEntry, openWindow: WindowOpener(openWindow))
        case .tryAgain:
            Task { await launch.tryAgain() }
        case .openAgentTooling:
            launch.bringMainForward(openWindow: WindowOpener(openWindow))
        case .checkApps:
            launch.checkApps()
        case .reviewChanges:
            launch.reviewChanges(openWindow: WindowOpener(openWindow))
        case .quit:
            launch.quit()
        case .opening, .couldNotOpen, .divider:
            break
        }
    }
}

// MARK: - The app's commands

/// The main menu's commands. Review Changes… (⇧⌘R), Check Apps (⇧⌘D) and
/// Hide Sidebar (⌃⌘S) act on the library only once the main window owns the
/// app, and never while the stage is the key window; Close (⌘W) asks the
/// stage before it closes and closes any other window; Set Up This Mac… opens
/// the stage at Your apps once there is a library to set up again.
struct AppCommands: Commands {
    let launch: AppLaunchState
    @Binding var sidebarCollapsed: Bool

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            SetUpThisMacCommand(launch: launch)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close") { launch.closeKeyWindow() }
                .keyboardShortcut("w")
        }
        CommandGroup(after: .newItem) {
            // The same review the menu-bar item and the palette open, under
            // the same name; a menu title-cases it.
            Button(ActionTitles.reviewChangesCommand(.menu)) { launch.reviewChanges() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(launch.commandWorkspace?.deployment.isBusy != false)
            Button(ActionTitles.checkAppsCommand(.menu)) { launch.checkApps() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(launch.commandWorkspace?.device.isChecking != false)
        }
        CommandGroup(after: .sidebar) {
            Button(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") { sidebarCollapsed.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(launch.commandWorkspace == nil)
        }
    }
}

/// The app menu's Set Up This Mac…: the stage at Your apps, with no fork,
/// over the library this Mac has. Disabled until the main window owns the
/// app; during a first run the menu-bar item's Show Setup brings the stage
/// forward instead.
struct SetUpThisMacCommand: View {
    let launch: AppLaunchState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(ActionTitles.setUpThisMacCommand(.menu)) {
            launch.presentStage(.rerun, openWindow: WindowOpener(openWindow))
        }
        .disabled(launch.readyWorkspace == nil)
    }
}

// MARK: - Preferences

extension View {
    /// The app's own preferences for everything under this root: the
    /// launch's one store (`AppLaunchState.defaults`), which
    /// `--defaults-suite` points at a suite of its own. What AppKit keeps for
    /// itself stays in the app's own domain (`LaunchContext`); the main window
    /// turns its frame and divider autosave off in a scratch run.
    func launchPreferences(_ defaults: UserDefaults) -> some View {
        defaultAppStorage(defaults)
    }
}
