import Foundation

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
    /// Where each client's tool is installed, in the order they are checked.
    public static func candidates(for client: ClientKind, homeURL: URL) -> [URL] {
        let name = executableName(for: client)
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            homeURL.appending(path: ".local/bin"),
            homeURL.appending(path: ".bun/bin"),
            homeURL.appending(path: ".npm-global/bin"),
        ].map { $0.appending(path: name).standardizedFileURL }
    }

    public static func executableName(for client: ClientKind) -> String {
        switch client {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
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
