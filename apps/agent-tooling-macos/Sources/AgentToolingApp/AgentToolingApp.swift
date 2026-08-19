import AgentToolingCore
import SwiftUI

@main
struct AgentToolingApplication: App {
    @State private var model: AppModel?
    @State private var startupError: String?
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false

    init() {
        do {
            _model = State(initialValue: try AppModel.live())
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
            model = try AppModel.live()
            startupError = nil
        } catch {
            model = nil
            startupError = error.localizedDescription
        }
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
