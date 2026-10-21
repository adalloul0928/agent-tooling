import Foundation
import os

/// Finds runnable client tools in known installation folders and explicitly
/// registered directories. Excludes inherited PATH because a macOS app's
/// launch environment may differ from the user's shell. Only existing,
/// runnable candidates may appear in a reviewed command.
public enum ClientExecutableLocator {
    /// Folders somebody explicitly recorded as holding client tools, applied to
    /// every lookup in this process. Registered from the device's own record at
    /// launch and after a reviewed find — never harvested from `PATH` silently.
    /// A lock rather than an actor because callers are synchronous and the
    /// value changes a handful of times per launch.
    private static let recordedRoots = OSAllocatedUnfairLock<[URL]>(initialState: [])

    /// Replaces the recorded custom roots. Non-absolute paths are refused here
    /// so a bad record degrades to the fixed roots instead of a bad probe.
    public static func registerAdditionalRoots(_ directories: [String]) {
        let roots =
            directories
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { NativeSkillDestination.isValidRoot($0) }
        recordedRoots.withLock { $0 = roots }
    }

    /// Where each client's tool is installed, in the order they are checked:
    /// the folders somebody recorded for this Mac first, then the fixed roots.
    public static func candidates(for client: ClientKind, homeURL: URL) -> [URL] {
        let name = executableName(for: client)
        var roots = recordedRoots.withLock { $0 }
        roots.append(contentsOf: fixedRoots(homeURL: homeURL).filter { root in !roots.contains(root) })
        return roots.map { $0.appending(path: name).standardizedFileURL }
    }

    /// Standard install folders, followed by the remaining shared search roots.
    static func fixedRoots(homeURL: URL) -> [URL] {
        let home = ProcessCommandRunner.plainPath(of: homeURL)
        let shared = ProcessCommandRunner.searchPath(home: home)
        let first = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
        ]
        .filter(shared.contains)
        return (first + shared.filter { !first.contains($0) }).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    public static func executableName(for client: ClientKind) -> String {
        switch client {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .kiro: "kiro-cli"
        }
    }

    /// Returns the first runnable candidate, preserving its symlink path.
    /// Resolving the target checks executability; retaining the command's name
    /// preserves argv[0] behavior and a stable path across versioned installs.
    /// The executor accepts this same path and follows the link at launch.
    public static func locate(
        _ client: ClientKind,
        homeURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        locate(client, homeURL: homeURL, fileManager: fileManager, searching: { _ in true })
    }

    /// `locate`, looking only in the folders `searching` keeps, in the same
    /// order and by the same checks. For tests and their shared fixtures: the
    /// fixed roots start with folders every process on the Mac shares, such as
    /// `/opt/homebrew/bin`, and a test must not find a tool that the Mac
    /// running it happens to have installed there.
    public static func locate(
        _ client: ClientKind,
        homeURL: URL,
        fileManager: FileManager = .default,
        searching: (URL) -> Bool
    ) -> URL? {
        for candidate in candidates(for: client, homeURL: homeURL) where searching(candidate.deletingLastPathComponent()) {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                fileManager.isExecutableFile(atPath: resolved.path),
                NativeSkillDestination.isValidRoot(candidate)
            else { continue }
            return candidate
        }
        return nil
    }
}
