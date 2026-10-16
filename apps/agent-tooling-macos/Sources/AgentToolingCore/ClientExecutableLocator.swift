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
    public static func candidates(for client: ClientKind, homeURL: URL) -> [URL] {
        let name = executableName(for: client)
        var roots = recordedRoots.withLock { $0 }
        roots.append(contentsOf: fixedRoots(homeURL: homeURL).filter { root in !roots.contains(root) })
        return roots.map { $0.appending(path: name).standardizedFileURL }
    }

    /// The fixed roots, in the order they are checked. They are the folders on
    /// the search path every child process gets, so a tool a child could start
    /// by name is a tool found here; only the order is the locator's own.
    ///
    /// Six come first, in the order they always have, so a tool found before is
    /// the tool found now; every other folder follows in the search path's own
    /// order. `~/.toolbox/bin` is Amazon Toolbox's shim directory: internal
    /// builds of these clients install there as symlinks to a dispatcher, which
    /// the runnability check follows like any other link. It is checked before
    /// the per-user install folders because a Mac that has it usually also has
    /// an older native install beside it, and the managed shim is the one the
    /// person's shell runs and the one that carries their sign-in.
    static func fixedRoots(homeURL: URL) -> [URL] {
        let home = ProcessCommandRunner.plainPath(of: homeURL)
        let shared = ProcessCommandRunner.searchPath(home: home)
        let first = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.toolbox/bin",
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
