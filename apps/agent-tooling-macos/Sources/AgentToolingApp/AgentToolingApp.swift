import AgentToolingCore
import SwiftUI

@main
struct AgentToolingApplication: App {
    @State private var model: AppModel?
    @State private var startupError: String?
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var navigation = AppNavigationState()

    init() {
        do {
            let launchContext = LaunchContext.current
            if let workspaceRoot = launchContext.workspaceRoot {
                _model = State(
                    initialValue: try AppModel(
                        store: WorkspaceStore(rootURL: workspaceRoot),
                        homeURL: launchContext.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser
                    )
                )
            } else {
                _model = State(
                    initialValue: try AppModel.live(homeURL: launchContext.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser))
            }
            _startupError = State(initialValue: nil)
        } catch {
            _model = State(initialValue: nil)
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        Window("Agent Tooling", id: "main") {
            Group {
                if let model {
                    AppShellView(initialSelection: launchSelection)
                        .environment(model)
                        .environment(navigation)
                } else {
                    StartupFailureView(message: startupError ?? "The local workspace could not be opened.") {
                        loadModel()
                    }
                }
            }
            .frame(minWidth: 1_180, minHeight: 760)
            .containerBackground(.clear, for: .window)
            .background(WindowConfigurator())
            .preferredColorScheme(colorScheme)
            .onOpenURL { url in
                guard navigation.open(url: url) else {
                    model?.presentError("Agent Tooling rejected an invalid or unsupported link.")
                    return
                }
                bringMainWindowForward()
            }
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Agent Tooling") {
                    guard let model else { return }
                    Task { await model.runSync() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model == nil || model?.isInteractionLocked == true)

                Button("Check Setup") {
                    guard let model else { return }
                    Task { await model.runDoctor() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model == nil || model?.isInteractionLocked == true)
            }
            CommandGroup(after: .sidebar) {
                Button(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    sidebarCollapsed.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        MenuBarExtra("Agent Tooling", systemImage: "slider.horizontal.3", isInserted: $showMenuBarItem) {
            if let model {
                MenuBarContent()
                    .environment(model)
            } else {
                Text("Agent Tooling could not open its workspace")
                Button("Retry") { loadModel() }
                Divider()
                Button("Quit Agent Tooling") { NSApp.terminate(nil) }
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "Dark": .dark
        case "System": nil
        default: .light
        }
    }

    private var launchSelection: AppSection {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--agent-tooling-section"), arguments.indices.contains(index + 1) else {
            return .overview
        }

        let requestedSection = arguments[index + 1].lowercased()
        return AppSection.allCases.first { $0.rawValue.lowercased() == requestedSection } ?? .overview
    }

    private func loadModel() {
        do {
            let launchContext = LaunchContext.current
            if let workspaceRoot = launchContext.workspaceRoot {
                model = try AppModel(
                    store: WorkspaceStore(rootURL: workspaceRoot),
                    homeURL: launchContext.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser
                )
            } else {
                model = try AppModel.live(homeURL: launchContext.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser)
            }
            startupError = nil
        } catch {
            model = nil
            startupError = error.localizedDescription
        }
    }

    private func bringMainWindowForward() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "agent-tooling-main" }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Development-only launch overrides let visual and interaction tests use a
/// disposable workspace instead of touching the person's real library.
private struct LaunchContext {
    var workspaceRoot: URL?
    var homeRoot: URL?

    static var current: LaunchContext {
        let arguments = ProcessInfo.processInfo.arguments
        return LaunchContext(
            workspaceRoot: value(after: "--agent-tooling-workspace", in: arguments).map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            },
            homeRoot: value(after: "--agent-tooling-home", in: arguments).map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            }
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private struct StartupFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Local workspace unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.bordered)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open Agent Tooling") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(model.isRunningDoctor ? "Checking setup…" : "Check Setup") {
            Task { await model.runDoctor() }
        }
        .disabled(model.isInteractionLocked)
        Button(model.isSyncing ? "Preparing changes…" : "Review sync") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.runSync() }
        }
        .disabled(model.isInteractionLocked)
        Divider()
        Button("Quit Agent Tooling") { NSApp.terminate(nil) }
    }
}
