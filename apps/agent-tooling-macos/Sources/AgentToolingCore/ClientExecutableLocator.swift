import Foundation
import os

/// Finds a client's command-line tool on this Mac.
///
/// Only places that actually hold a runnable file count. A path that is not
/// there is not returned as a guess, because the caller's next step is to put
/// that path into a command a person is asked to approve, and an approval for a
/// command that cannot run is worse than no offer at all.
///
/// `PATH` is not searched. It is inherited from whatever launched the app, which
/// on macOS is usually not the shell environment a person thinks they have, so a
/// hit there would be neither reproducible nor explainable.
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
        let roots = directories
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { NativeSkillDestination.isValidRoot($0) }
        recordedRoots.withLock { $0 = roots }
    }

    /// Where each client's tool is installed, in the order they are checked:
    /// the folders somebody recorded for this Mac first, then the fixed roots.
    /// `~/.toolbox/bin` is Amazon Toolbox's shim directory: internal builds of
    /// these clients install there as symlinks to a dispatcher, which the
    /// runnability check follows like any other link.
    public static func candidates(for client: ClientKind, homeURL: URL) -> [URL] {
        let name = executableName(for: client)
        let fixed = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            homeURL.appending(path: ".local/bin"),
            homeURL.appending(path: ".bun/bin"),
            homeURL.appending(path: ".npm-global/bin"),
            homeURL.appending(path: ".toolbox/bin"),
        ]
        var roots = recordedRoots.withLock { $0 }
        roots.append(contentsOf: fixed.filter { root in !roots.contains(root) })
        return roots.map { $0.appending(path: name).standardizedFileURL }
    }

    public static func executableName(for client: ClientKind) -> String {
        switch client {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .kiro: "kiro-cli"
        }
    }

    /// The first candidate whose file is runnable, or `nil`.
    ///
    /// A link is followed to test what it leads to, because that is the file
    /// that will run. The path returned is the candidate itself, by the tool's
    /// own name, because the file behind it need not carry that name at all:
    /// Claude Code's installer keeps the binary as
    /// `~/.local/share/claude/versions/2.1.268` and points `~/.local/bin/claude`
    /// at it, renaming the file on every update, and the ChatGPT app's `codex`
    /// lives inside its bundle. The launch path follows the link again at the
    /// moment of running, and the executor's policy accepts exactly this path.
    public static func locate(
        _ client: ClientKind,
        homeURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in candidates(for: client, homeURL: homeURL) {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: resolved.path),
                  NativeSkillDestination.isValidRoot(candidate) else { continue }
            return candidate
        }
        return nil
    }
}
