import Foundation

/// Finds a missing client tool the deterministic way: by asking the person's
/// own login shell where the command lives. `command -v` in `zsh -l` reproduces
/// exactly what their terminal would find — no AI, no guessing, and nothing is
/// recorded here. The caller shows or records the answer through its own
/// reviewed path.
///
/// This deliberately complements, rather than replaces, the locator's fixed
/// roots: an ambient `PATH` inherited by a GUI app is not the shell's, which is
/// why the locator never reads it. Launching the login shell explicitly asks
/// the right environment the reproducible way.
public enum SmartToolFinder {
    public struct Finding: Hashable, Sendable {
        public let client: ClientKind
        public let executableURL: URL

        public init(client: ClientKind, executableURL: URL) {
            self.client = client
            self.executableURL = executableURL
        }

        public var directory: URL { executableURL.deletingLastPathComponent() }
    }

    /// Asks the login shell for each client's tool. The command name is the
    /// locator's own fixed vocabulary, never caller input, so nothing user-
    /// controlled reaches the shell line. A tool that resolves to something
    /// not runnable, relative, or renamed is dropped rather than recorded.
    public static func probe(
        clients: [ClientKind],
        runner: any CommandRunning,
        fileManager: FileManager = .default
    ) async -> [Finding] {
        var findings: [Finding] = []
        for client in clients {
            let name = ClientExecutableLocator.executableName(for: client)
            guard
                let output = try? await runner.run(
                    executable: "/bin/zsh", arguments: ["-l", "-c", "command -v \(name)"],
                    currentDirectory: nil),
                output.status == 0
            else { continue }
            let path = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\n") else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.lastPathComponent == name,
                NativeSkillDestination.isValidRoot(url),
                fileManager.isExecutableFile(atPath: url.resolvingSymlinksInPath().path)
            else { continue }
            findings.append(Finding(client: client, executableURL: url))
        }
        return findings
    }
}
