import Foundation

/// A command as a person reads it, for looking at only: the tool's own name,
/// never the folder it was found in, then its arguments, an argument holding
/// whitespace set in double quotes.
///
/// The review sheet's wells, the stage's review panel, setup's list of what
/// it runs and the helper's preview all show commands, and each built the
/// string its own way. This is the one way, so a command reads the same on
/// every surface it appears on. It is never parsed back or run.
enum CommandLineDisplay {
    /// `claude mcp add --scope user agent-tooling -- "/Applications/Agent Tooling.app/…"`.
    static func rendered(executable: URL, arguments: [String]) -> String {
        rendered(executableName: executable.lastPathComponent, arguments: arguments)
    }

    /// The same, from the tool's name rather than its path.
    static func rendered(executableName: String, arguments: [String]) -> String {
        ([executableName] + arguments)
            .map { $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }
}
