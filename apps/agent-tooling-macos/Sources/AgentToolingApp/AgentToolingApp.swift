import AgentToolingCore
import SwiftUI

@main
struct AgentToolingApplication: App {
    @State private var workspace: WorkspaceLaunch.Workspace?
    @State private var startupError: String?
    @AppStorage("appearance") private var appearance = "System"

    var body: some Scene {
        Window("Agent Tooling", id: "main") {
            Group {
                if let workspace {
                    WorkspaceShellView(
                        session: workspace.library, syncSession: workspace.sync,
                        settingsSession: workspace.settings, deploymentSession: workspace.deployment,
                        historySession: workspace.history, authoringSession: workspace.authoring,
                        exportSession: workspace.export, presetsSession: workspace.presets,
                        declarationSession: workspace.declarations)
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
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

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
        } catch {
            workspace = nil
            startupError = error.localizedDescription
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }
}

private struct AppearanceSettingsView: View {
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

/// Where this launch was told to look. Used by tests and packaged pilots to
/// point the app at a scratch folder; absent in ordinary use.
struct LaunchContext {
    var workspaceRoot: URL?
    var homeRoot: URL?

    static var current: LaunchContext {
        var context = LaunchContext()
        var arguments = ProcessInfo.processInfo.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--workspace": context.workspaceRoot = arguments.next().map { URL(fileURLWithPath: $0).standardizedFileURL }
            case "--home": context.homeRoot = arguments.next().map { URL(fileURLWithPath: $0).standardizedFileURL }
            default: continue
            }
        }
        return context
    }
}
