import AgentToolingCore
import Foundation

/// The other ways to use Agent Tooling on this Mac: Raycast with the Agent
/// Tooling extension, and the command-line tool inside the app.
///
/// Looked for only when Home's tips are opened, never while Home draws: the
/// look reads two folders and the extensions' manifests, and Home's own
/// rule is that drawing it reads nothing.
enum CompanionPresence {
    /// Where Raycast stands on this Mac.
    enum Raycast: Equatable, Sendable {
        case absent
        /// Raycast is here; the Agent Tooling extension is not.
        case appOnly
        case extensionInstalled
    }

    /// The name Raycast knows the extension by, as its manifest declares it
    /// (`integrations/raycast/agent-tooling/package.json`).
    static let raycastExtensionName = "agent-tooling"

    /// The extension's commands, as Raycast lists them. They are the
    /// extension's own names, kept here rather than with the tips' sentences
    /// because they are names, not words of the app's.
    static let raycastCommands = [
        "Search Agent Tooling", "Create Skill Draft", "Check Setup", "Review Sync", "Review Tooling Insights",
        "Open Agent Tooling",
    ]

    /// The most extension folders and manifest bytes the look reads.
    static let extensionLimit = 500
    static let manifestByteLimit = 262_144

    /// Whether Raycast is in `/Applications` or `~/Applications`, and whether
    /// one of its installed extensions is Agent Tooling's.
    static func raycast(
        home: URL, applications: [URL] = [URL(filePath: "/Applications", directoryHint: .isDirectory)],
        fileManager: FileManager = .default
    ) -> Raycast {
        let folders = applications + [home.appending(path: "Applications", directoryHint: .isDirectory)]
        let installed = folders.contains { folder in
            fileManager.fileExists(atPath: folder.appending(path: "Raycast.app").path(percentEncoded: false))
        }
        guard installed else { return .absent }
        let extensions = home.appending(path: ".config/raycast/extensions", directoryHint: .isDirectory)
        let entries = (try? fileManager.contentsOfDirectory(at: extensions, includingPropertiesForKeys: nil)) ?? []
        for entry in entries.prefix(extensionLimit) where isAgentTooling(entry.appending(path: "package.json"), fileManager) {
            return .extensionInstalled
        }
        return .appOnly
    }

    /// The command-line tool inside this copy, when it has one.
    static func commandLineHelper(_ installation: AgentToolingInstallation) -> String? {
        installation.cliHelperURL?.path(percentEncoded: false)
    }

    private static func isAgentTooling(_ manifest: URL, _ fileManager: FileManager) -> Bool {
        let path = manifest.path(percentEncoded: false)
        guard let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int, size <= manifestByteLimit,
            let data = fileManager.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["name"] as? String == raycastExtensionName
    }
}
