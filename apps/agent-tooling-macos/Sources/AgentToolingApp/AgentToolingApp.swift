import AgentToolingCore
import SwiftUI

@main
struct AgentToolingApplication: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    /// Shared outside window lifecycles so menu-bar commands and links use the same
    /// navigation, and opening the library does not depend on a visible window.
    @State private var launch: AppLaunchState
    @AppStorage private var appearance: String
    @AppStorage private var showMenuBarItem: Bool
    @AppStorage private var sidebarCollapsed: Bool

    init() {
        // First, before anything about the launch is decided or read.
        if ProcessInfo.processInfo.arguments.contains("--verify-resources") {
            do {
                try AppResources.verifyPackagedResources()
                print("Packaged third-party notices verified.")
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        let launch = AppLaunchState.live(context: LaunchContext.current)
        AppLaunchState.active = launch
        _launch = State(initialValue: launch)
        // The launch's one store, which every scene's root shares.
        _appearance = AppPreferences.appearance(launch.defaults)
        _showMenuBarItem = AppPreferences.showMenuBarItem(launch.defaults)
        _sidebarCollapsed = AppPreferences.sidebarCollapsed(launch.defaults)
    }

    var body: some Scene {
        // The shell's window. Suppressed while setup owns the app; it opens at
        // the hand-off, and on any later launch. It takes links only once the
        // stage no longer does.
        Window("Agent Tooling", id: AppWindow.main.sceneID) {
            MainWindowRoot(launch: launch)
                .launchPreferences(launch.defaults)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(WindowSize.standard)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultLaunchBehavior(launch.mainLaunchBehavior)
        .handlesExternalEvents(matching: launch.ownsLaunch ? [] : ["*"])
        .commands {
            AppCommands(launch: launch, sidebarCollapsed: $sidebarCollapsed)
        }

        // Setup owns incoming links until hand-off; queue them for the shell.
        // This fixed-size stage is excluded from restoration and the Window menu.
        Window(LaunchpadCopy.Welcome.windowTitle, id: AppWindow.setup.sceneID) {
            SetupStageWindow(launch: launch)
                .launchPreferences(launch.defaults)
                .preferredColorScheme(colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(launch.stageLaunchBehavior)
        .handlesExternalEvents(matching: launch.ownsLaunch ? ["*"] : [])
        .commandsRemoved()

        MenuBarExtra("Agent Tooling", systemImage: "slider.horizontal.3", isInserted: $showMenuBarItem) {
            MenuBarRoot(launch: launch)
                .launchPreferences(launch.defaults)
        }

        Settings {
            // The system Settings window keeps the grouped-form idiom it is
            // expected to have; the in-app Settings screen shows the same
            // binding as one row in its own card.
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: WindowSize.settingsWidth)
            .launchPreferences(launch.defaults)
        }
    }

    private var colorScheme: ColorScheme? {
        AppAppearance(appearance).colorScheme
    }
}

/// The app's own preferences the `App` reads itself, each kept in the
/// launch's defaults, so `--defaults-suite` moves them with every screen's.
enum AppPreferences {
    static func appearance(_ defaults: UserDefaults) -> AppStorage<String> {
        AppStorage(wrappedValue: AppAppearance.system.rawValue, AppPreferenceKey.appearance, store: defaults)
    }

    static func showMenuBarItem(_ defaults: UserDefaults) -> AppStorage<Bool> {
        AppStorage(wrappedValue: true, AppPreferenceKey.showMenuBarItem, store: defaults)
    }

    static func sidebarCollapsed(_ defaults: UserDefaults) -> AppStorage<Bool> {
        AppStorage(wrappedValue: false, AppPreferenceKey.sidebarCollapsed, store: defaults)
    }
}

struct AppearanceSettingsView: View {
    @Binding var appearance: String

    var body: some View {
        // Use a row here: a grouped Form would nest its own card inside this card.
        InfoRow("Light or dark", detail: "System follows macOS.") {
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).frame(width: Size.glyphSlot)
        } trailing: {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Recovery after a readable locator fails to open its library. Unreadable
/// locators are handled by the setup stage.
struct StartupFailureView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(LaunchpadCopy.Welcome.couldNotOpenWorkspace, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry).primaryActionStyle()
        }
    }
}

/// Launch arguments, read once by `current`.
/// `--workspace` and `--home` select data roots; `--section` and `--request` select
/// navigation. `--defaults-suite` isolates app preferences, but AppKit may still
/// read saved frames and maintain system panel preferences in the app domain.
/// `--after-move <pid> [<volume>]` identifies the old instance and optional image;
/// its parser never consumes the next flag as a value.
/// Installation and Applications-folder overrides require `--workspace`.
struct LaunchContext: Sendable {
    var workspaceRoot: URL?
    var homeRoot: URL?
    /// The screen this launch opens on. Absent means Home.
    var section: AppSection?
    /// A screen request to open on, such as `reviewChanges`; its section wins.
    var request: ScreenRequest?
    /// The defaults suite the app's own preferences are kept in, if not the
    /// app's own domain.
    var defaultsSuite: String?
    /// The move to Applications this copy was opened to finish.
    var afterMove: AfterMove?
    private var requestedInstallation: InstallationOverride?
    private var requestedApplicationsFolder: URL?

    /// Waits for the old process to exit, then ejects its optional disk image.
    /// Translocated and ordinary-folder launches have no volume to eject.
    struct AfterMove: Equatable, Sendable {
        var pid: Int32
        var volume: URL?
    }

    /// Where a rehearsal says this copy runs from.
    enum InstallationOverride: String, CaseIterable, Sendable {
        case applications
        case diskImage = "disk-image"
        case translocated
        case elsewhere
        case development
    }

    /// This process's own arguments, read once.
    static let current = LaunchContext(arguments: ProcessInfo.processInfo.arguments)

    /// The context `arguments` describe. The first is the executable, as in
    /// `ProcessInfo.arguments`, and is skipped.
    init(arguments: [String] = []) {
        var arguments = LaunchArguments(arguments.dropFirst())
        while let argument = arguments.next() {
            switch argument {
            case "--workspace":
                workspaceRoot = arguments.next().map { URL(fileURLWithPath: $0).standardizedFileURL }
            case "--home":
                homeRoot = arguments.next().map { URL(fileURLWithPath: $0).standardizedFileURL }
            case "--section":
                section = arguments.next().flatMap(AppSection.named)
            case "--request":
                request = arguments.next().flatMap(ScreenRequest.named)
            case "--defaults-suite":
                defaultsSuite = arguments.next().flatMap { $0.isEmpty ? nil : $0 }
            case "--after-move":
                guard let pid = arguments.next(where: { Int32($0) != nil }).flatMap({ Int32($0) }) else { continue }
                let volume = arguments.next(where: { !$0.isEmpty && !$0.hasPrefix("--") }).map {
                    URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
                }
                afterMove = AfterMove(pid: pid, volume: volume)
            case "--installation-override":
                requestedInstallation = arguments.next().flatMap(InstallationOverride.init(rawValue:))
            case "--applications-folder":
                requestedApplicationsFolder = arguments.next().map {
                    URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
                }
            default: continue
            }
        }
    }

    /// The app's own preferences: the suite `--defaults-suite` names, or the
    /// app's own domain. Each read makes a new store object, so the launch
    /// reads it once (`AppLaunchState.defaults`) and shares that.
    var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Where a rehearsal says this copy runs from, only beside `--workspace`.
    var installationOverride: InstallationOverride? {
        workspaceRoot == nil ? nil : requestedInstallation
    }

    /// The Applications folder a rehearsal moves into, only beside
    /// `--workspace`; nil means `/Applications`.
    var applicationsFolder: URL? {
        workspaceRoot == nil ? nil : requestedApplicationsFolder
    }

    /// This copy as inspection found it, or as a rehearsal says it runs from.
    /// The bundle, its helpers and its signature stay this copy's own; only
    /// where it is changes.
    func installation(inspected: AgentToolingInstallation) -> AgentToolingInstallation {
        guard let override = installationOverride else { return inspected }
        let bundle = inspected.bundleURL
        let location: AgentToolingInstallation.Location
        switch override {
        case .applications:
            location = .applications(applicationsFolder ?? URL(filePath: "/Applications", directoryHint: .isDirectory))
        case .diskImage:
            location = .diskImage(
                volumeName: "Agent Tooling", volumeURL: URL(filePath: "/Volumes/Agent Tooling", directoryHint: .isDirectory))
        case .translocated:
            location = .translocated(bundle)
        case .elsewhere:
            location = .elsewhere(bundle.deletingLastPathComponent())
        case .development:
            location = .developmentBuild
        }
        let helpers = bundle.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        return AgentToolingInstallation(
            bundleURL: bundle, location: location,
            mcpHelperURL: inspected.mcpHelperURL ?? Self.executable(helpers.appending(path: "agent-tooling-mcp")),
            cliHelperURL: inspected.cliHelperURL ?? Self.executable(helpers.appending(path: "agent-tooling")),
            isAdHocSigned: inspected.isAdHocSigned)
    }

    /// `url` when it is a file this user may run.
    private static func executable(_ url: URL) -> URL? {
        FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}

/// A launch's arguments, read front to back.
private struct LaunchArguments {
    private var rest: ArraySlice<String>

    init(_ arguments: ArraySlice<String>) {
        rest = arguments
    }

    /// The next argument, whatever it is.
    mutating func next() -> String? {
        rest.popFirst()
    }

    /// The next argument when `accepts` takes it as this flag's value;
    /// otherwise it is left to be read as what it is.
    mutating func next(where accepts: (String) -> Bool) -> String? {
        guard let first = rest.first, accepts(first) else { return nil }
        return rest.popFirst()
    }
}

extension AppSection {
    /// Accepts durable display names and code names used by scripts. Unknown names
    /// return nil so launch falls back to Home.
    static func named(_ name: String) -> AppSection? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return allCases.first {
            $0.rawValue.lowercased() == wanted || String(describing: $0).lowercased() == wanted
        }
    }
}
