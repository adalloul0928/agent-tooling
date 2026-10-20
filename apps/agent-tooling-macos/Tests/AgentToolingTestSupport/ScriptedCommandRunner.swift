import AgentToolingCore
import Foundation

/// One command a test double was asked to run.
public struct CommandLaunch: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The executable's file name. A test compares this rather than the path,
    /// because the folder a tool is found in differs from one Mac to another.
    public var basename: String { URL(fileURLWithPath: executable).lastPathComponent }

    /// The command as a person reads it: `codex plugin list --json`.
    public var display: String { ([basename] + arguments).joined(separator: " ") }
}

/// Answers commands by exact argument list and records every call.
///
/// This is the recurring "scripted runner" test double: a dictionary from an
/// argument array to the output it should return, a record of what was asked,
/// and an unscripted-call default of status 1 (matching the hand-rolled
/// `ArgumentScriptedRunner` and friends). It is an actor so the recording needs
/// no manual lock.
///
/// Scripts keyed by the tool's own name answer each tool differently, the way
/// `codex --version` and `claude --version` do, and can also time out or hang
/// until the caller is cancelled.
public actor ScriptedCommandRunner: CommandRunning {
    /// How a command keyed by its tool answers.
    public enum Reply: Sendable {
        /// Returns this output.
        case output(CommandOutput)
        /// Throws `ProcessCommandRunnerError.timedOut`, as the real runner
        /// does for a command that ran past its time.
        case timeOut
        /// Answers nothing until the calling task is cancelled, then throws
        /// `CancellationError`, as the real runner does when it stops a child.
        case hangUntilCancelled

        /// A successful command that printed `text`.
        public static func standardOutput(_ text: String) -> Reply {
            .output(CommandOutput(status: 0, standardOutput: text, standardError: ""))
        }
    }

    private let outputs: [[String]: CommandOutput]
    private let byTool: [String: [[String]: Reply]]
    private let missingTools: Set<String>
    private var asked: [CommandLaunch] = []

    /// Scripts outputs keyed by the exact argument list. A missing key answers
    /// status 1 with the message "not scripted".
    public init(_ outputs: [[String]: CommandOutput]) {
        self.outputs = outputs
        byTool = [:]
        missingTools = []
    }

    /// Convenience for the common case of scripting only standard output on a
    /// successful (status 0) command.
    public init(standardOutput: [[String]: String]) {
        self.outputs = standardOutput.mapValues {
            CommandOutput(status: 0, standardOutput: $0, standardError: "")
        }
        byTool = [:]
        missingTools = []
    }

    /// Scripts replies keyed first by the executable's file name, then by the
    /// exact argument list. Any other call to a tool in `missingTools` answers
    /// as a missing executable does (status 127). A call nothing else answers
    /// falls back to `fallback`, keyed by arguments alone, and then to status 1.
    public init(
        byTool: [String: [[String]: Reply]], fallback: [[String]: CommandOutput] = [:], missingTools: Set<String> = []
    ) {
        self.byTool = byTool
        outputs = fallback
        self.missingTools = missingTools
    }

    /// The argument lists seen so far, in call order.
    public var calls: [[String]] { asked.map(\.arguments) }

    /// Every call so far, executable included, in call order.
    public var launches: [CommandLaunch] { asked }

    public func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        let launch = CommandLaunch(executable: executable, arguments: arguments)
        asked.append(launch)
        switch byTool[launch.basename]?[arguments] {
        case .output(let output):
            return output
        case .timeOut:
            throw ProcessCommandRunnerError.timedOut(executable)
        case .hangUntilCancelled:
            try await CancellationLatch.waitUntilCancelled()
            throw CancellationError()
        case nil:
            if missingTools.contains(launch.basename) {
                return CommandOutput(status: 127, standardOutput: "", standardError: "command not found: \(executable)")
            }
            return outputs[arguments] ?? CommandOutput(status: 1, standardOutput: "", standardError: "not scripted")
        }
    }
}

/// A runner for a client whose CLI is absent: every command answers as the
/// shell does for a missing executable (status 127, "command not found").
///
/// Matches the "refuse everything" doubles that stand in for an uninstalled
/// tool. Runners that must report a different status (for example a signed-out
/// `--version` returning 3) stay bespoke in their own suite.
public struct RefusingCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "command not found: \(executable)")
    }
}
