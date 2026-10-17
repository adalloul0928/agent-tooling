import AgentToolingCore
import AppKit
import Foundation
import SwiftUI

/// Opening a client in Terminal with one skill invoked, behind a protocol.
///
/// The live one writes a `.command` file and asks Terminal.app to open it. A
/// render test hands in one that records the request, so laying out a detail
/// pane can never open a window on somebody's Mac.
protocol SkillTrialOpening: Sendable {
    /// Whether this Mac can try a skill in `client` at all: the client is
    /// supported and its tool was found.
    func canTry(in client: ClientKind) -> Bool
    /// Prepares the launch and opens it in Terminal.
    func tryOut(skillName: String, in client: ClientKind) async throws -> SkillTrialLaunch
}

struct LiveSkillTrialOpening: SkillTrialOpening {
    let homeRoot: URL
    let scriptsDirectory: URL

    func canTry(in client: ClientKind) -> Bool {
        SkillTrialCommandShapes.isSupported(client) && ClientExecutableLocator.locate(client, homeURL: homeRoot) != nil
    }

    func tryOut(skillName: String, in client: ClientKind) async throws -> SkillTrialLaunch {
        let launch = try SkillTrialLauncher(homeURL: homeRoot, scriptsDirectory: scriptsDirectory)
            .prepare(client: client, skillName: skillName)
        // Terminal.app by its own path rather than whatever handles `.command`
        // files today, so the script runs where the person expects and nowhere
        // else. Terminal executes the file in a new window.
        let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.open([launch.scriptURL], withApplicationAt: terminal, configuration: configuration)
        return launch
    }
}

extension WorkspaceLaunch.Workspace {
    /// Where trial scripts are written: inside this workspace's own container,
    /// beside its cache, and nowhere a client would ever read.
    var skillTrialScriptsDirectory: URL {
        store.databaseURL.deletingLastPathComponent()
            .appending(path: "cache", directoryHint: .isDirectory)
            .appending(path: "terminal-launches", directoryHint: .isDirectory)
    }
}

extension EnvironmentValues {
    /// How a detail pane opens a skill in Terminal. A test replaces the whole
    /// factory, so no render can open a window.
    @Entry var skillTrialOpening: (WorkspaceLaunch.Workspace) -> any SkillTrialOpening = {
        LiveSkillTrialOpening(homeRoot: $0.homeRoot, scriptsDirectory: $0.skillTrialScriptsDirectory)
    }
}
