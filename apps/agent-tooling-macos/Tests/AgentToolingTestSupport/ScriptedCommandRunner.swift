import AgentToolingCore
import Foundation

/// Answers commands by exact argument list and records every call.
///
/// This is the recurring "scripted runner" test double: a dictionary from an
/// argument array to the output it should return, a record of what was asked,
/// and an unscripted-call default of status 1 (matching the hand-rolled
/// `ArgumentScriptedRunner` and friends). It is an actor so the recording needs
/// no manual lock.
public actor ScriptedCommandRunner: CommandRunning {
    private let outputs: [[String]: CommandOutput]
    private var asked: [[String]] = []

    /// Scripts outputs keyed by the exact argument list. A missing key answers
    /// status 1 with the message "not scripted".
    public init(_ outputs: [[String]: CommandOutput]) {
        self.outputs = outputs
    }

    /// Convenience for the common case of scripting only standard output on a
    /// successful (status 0) command.
    public init(standardOutput: [[String]: String]) {
        self.outputs = standardOutput.mapValues {
            CommandOutput(status: 0, standardOutput: $0, standardError: "")
        }
    }

    /// The argument lists seen so far, in call order.
    public var calls: [[String]] { asked }

    public func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        asked.append(arguments)
        return outputs[arguments] ?? CommandOutput(status: 1, standardOutput: "", standardError: "not scripted")
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
