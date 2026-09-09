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

    /// The first candidate that is a runnable file, or `nil`.
    ///
    /// A symlink is resolved before the check, and the result is the resolved
    /// path — the command that runs is the file that was tested, not a link that
    /// might point somewhere else by the time it runs.
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
                  NativeSkillDestination.isValidRoot(resolved),
                  // The bridges require the tool's own name, so a link that
                  // resolves to something else entirely is not this client's.
                  resolved.lastPathComponent == executableName(for: client) else { continue }
            return resolved
        }
        return nil
    }
}
