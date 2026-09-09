import Foundation

/// The command a client uses to install one of its own packages.
///
/// Recorded rather than inferred, and recorded the same way the configuration
/// register records a setting: with the place it was read from and the release
/// it was checked against. An entry here is a claim that this exact command
/// works on that version, and it is the only place a command is written down.
///
/// This does not make running one automatic. A command from here still becomes
/// an operation a person approves, the executor still checks it against its own
/// policy, and the client's tool still has to be a runnable file on this Mac.
/// What the register removes is the earlier situation, where the only way to get
/// a command was to echo one back from a catalog record — which meant a package
/// nobody had catalogued could never be installed even though the command was
/// perfectly well known.
public struct NativePluginInstallCommand: Hashable, Sendable {
    public let client: ClientKind
    public let executable: String
    public let installArguments: [String]
    public let removeArguments: [String]
    /// The client release this was checked against, and where it was read.
    public let verifiedAgainstVersion: String
    public let source: String
}

public enum NativePluginInstallRegister {
    /// Verified on 2026-09-09 against the tools installed on this Mac, by
    /// reading each one's own `--help` output rather than trusting a page that
    /// may describe a different release.
    /// `nil` for a client with no recorded command. Gemini has none: nothing
    /// here has read one, and writing a plausible one would be the invention
    /// this register exists to avoid.
    public static func command(
        for client: ClientKind, externalPluginID: String
    ) -> NativePluginInstallCommand? {
        guard OperationCommandPolicy.isSafePluginIdentifier(externalPluginID) else { return nil }
        switch client {
        case .claude:
            return .init(
                client: .claude, executable: "claude",
                installArguments: ["plugin", "install", externalPluginID, "--scope", "user"],
                removeArguments: ["plugin", "uninstall", externalPluginID],
                verifiedAgainstVersion: "2.1.263",
                source: "claude plugin install --help; https://code.claude.com/docs/en/discover-plugins")
        case .codex:
            return .init(
                client: .codex, executable: "codex",
                installArguments: ["plugin", "add", externalPluginID],
                removeArguments: ["plugin", "remove", externalPluginID],
                verifiedAgainstVersion: "0.153.4",
                source: "codex plugin add --help; https://developers.openai.com/codex/concepts/customization")
        case .gemini:
            return nil
        }
    }

    /// The same command as a `NativeInstall`, which is the shape the command
    /// bridge already checks against.
    public static func reviewedInstall(
        for client: ClientKind, externalPluginID: String
    ) -> NativeInstall? {
        guard let command = command(for: client, externalPluginID: externalPluginID) else { return nil }
        return .init(client: command.client, executable: command.executable,
                     arguments: command.installArguments,
                     removalArguments: command.removeArguments, scope: .user,
                     detail: "Recorded for \(command.client.rawValue) \(command.verifiedAgainstVersion).")
    }
}
