import Foundation

/// The oldest client release each feature was checked against, as
/// `docs/compatibility.md` records it.
///
/// "Too old" is only ever a positive finding: a version this Mac read and
/// can compare that is below a recorded minimum. A version that is missing,
/// that does not parse, or that belongs to a client with no recorded minimum
/// (Gemini CLI and Kiro CLI today) is never too old, because claiming an
/// update is needed on no evidence would send a person to fix nothing.
public enum ClientCompatibility {
    /// What a minimum is the minimum for. They are different gates: the
    /// release gate is what this build was tested against; the readers need
    /// a release that answers the commands they ask.
    public enum Feature: String, CaseIterable, Sendable {
        /// The plugin, skill, MCP and marketplace behaviour of the release
        /// gate.
        case releaseGate
        /// Reading the hosted account the client signs in with.
        case accountReader
        /// Claude Code keeping the account's skills and plugins in step.
        case accountSync
    }

    /// The minimum for `feature` in `client`, as printed in the compatibility
    /// table, or nil when the table records none.
    static func minimum(_ feature: Feature, for client: ClientKind) -> String? {
        switch (client, feature) {
        case (.claude, .releaseGate): "2.1.207"
        case (.claude, .accountReader): "2.1.300"
        case (.claude, .accountSync): "2.1.273"
        case (.codex, .releaseGate): "0.144.0-alpha.4"
        case (.codex, .accountReader): "0.162.1"
        case (.codex, .accountSync), (.gemini, _), (.kiro, _): nil
        }
    }

    /// True only when `versionLine`, what the client's `--version` printed,
    /// holds a number below the recorded minimum for `feature`.
    public static func isBelow(_ feature: Feature, client: ClientKind, versionLine: String?) -> Bool {
        guard let required = minimum(feature, for: client),
            let installed = ClientVersionText.number(in: versionLine)
        else { return false }
        return ClientVersionText.compare(installed, required) == .orderedAscending
    }
}
