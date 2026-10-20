import AgentToolingCore
import Foundation

/// A client adapter whose scan answers a canned observation, optionally held
/// until a `GatedCommandRunner` lets it go.
///
/// For per-app progress (the scan has started and not finished), for a Stop
/// that must discard what was read, and for committing a workspace from
/// observations without reading anything. A held scan swallows its own
/// cancellation and still returns, as a real scan does; it is the reader's
/// job to notice the cancellation and keep nothing.
public struct ScriptedClientAdapter: ClientAdapter {
    public let client: ClientKind
    public let surface: TargetSurface
    public let capabilities: TargetCapabilities
    private let observation: TargetObservation
    private let gate: GatedCommandRunner?

    /// An adapter for `client` that answers `observation`. The gate, when
    /// given, is asked to run `scan <client>` before the scan answers.
    public init(_ observation: TargetObservation, client: ClientKind, gate: GatedCommandRunner? = nil) {
        self.client = client
        surface = observation.surface
        capabilities = observation.capabilities
        self.observation = observation
        self.gate = gate
    }

    /// The same, for the app the observation's surface belongs to. Nil when
    /// it belongs to none, for the suite to `#require`.
    public init?(_ observation: TargetObservation, gate: GatedCommandRunner? = nil) {
        guard let client = observation.surface.client else { return nil }
        self.init(observation, client: client, gate: gate)
    }

    public func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        if let gate { _ = try? await gate.run(executable: "scan", arguments: [client.rawValue], currentDirectory: nil) }
        return observation
    }

    /// Where the bundled adapter for the same app puts a skill, so a scripted
    /// workspace plans the destinations a scanned one would.
    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        ClientAdapterRegistry().adapter(for: client)?.skillDestination(skillID: skillID, homeURL: homeURL)
            ?? homeURL.appending(path: ".scripted/skills/\(skillID)", directoryHint: .isDirectory)
    }
}
