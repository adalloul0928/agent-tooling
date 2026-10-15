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

/// A runner for a client that is not installed: every command is refused.
///
/// Matches the "refuse everything" doubles that answer status 1 for any
/// command. Runners that must report a different status (for example `command
/// not found` as 127) stay bespoke in their own suite.
public struct RefusingCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 1, standardOutput: "", standardError: "refused")
    }
}
