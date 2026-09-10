import Foundation

/// Whether this Mac has a recorded way to install a client's own packages.
///
/// Asked through a closure rather than by calling `NativePluginInstallRegister`
/// directly, so a test can derive evidence for a client whose command is or is
/// not recorded without editing the register itself. The register is a list of
/// facts somebody checked against a real release; it is not a knob.
public struct NativePluginInstallSupport: Sendable {
    private let recorded: @Sendable (ClientKind) -> Bool

    public init(recorded: @escaping @Sendable (ClientKind) -> Bool) {
        self.recorded = recorded
    }

    public func hasRecordedInstallCommand(for client: ClientKind) -> Bool { recorded(client) }

    /// The register this app ships. The identifier below is a well-formed name
    /// to ask the question with; no command is built from it and none is run.
    public static let register = NativePluginInstallSupport { client in
        NativePluginInstallRegister.command(for: client, externalPluginID: "agent-tooling-probe") != nil
    }
}

extension TargetCapabilityEvidence {
    /// What this Mac's own scan says each installed client can be asked to
    /// carry.
    ///
    /// Capability evidence is the one thing standing between a saved assignment
    /// and a plan, and until this existed nothing in the shipping app ever wrote
    /// any: the resolver looked for a record that only tests had ever created,
    /// found none, and excluded every destination. This turns the scan that
    /// already runs into exactly the records that check is looking for.
    ///
    /// Nothing here probes anything new. Each record restates something already
    /// observed — the client answered its own `--version`, the adapter declares
    /// what it can be asked for — or something already written down, namely the
    /// commands the install register holds and the shapes the two command
    /// planners can express. A client that did not answer, or answered without a
    /// version, produces no record at all: the resolver's exclusion for missing
    /// evidence is the honest outcome there, and inventing a record would turn
    /// "nobody knows" into an install claim.
    ///
    /// One record per `(surface, component, transport)` and no more. The
    /// resolver and both planners require exactly one match and treat two as a
    /// contradiction, so a second record for one key would block the thing it
    /// was meant to allow.
    public static func derive(
        from observations: [TargetObservation],
        installRegister: NativePluginInstallSupport = .register,
        adapterContractVersion: UInt = WorkspaceSkillTargetCapture.adapterContractVersion
    ) -> [TargetCapabilityEvidence] {
        // A contract version of zero fails validation and matches no target, so
        // it would only ever produce records nothing could use.
        guard adapterContractVersion > 0 else { return [] }
        var occurrences: [TargetSurface: Int] = [:]
        for observation in observations { occurrences[observation.surface, default: 0] += 1 }
        var records: [TargetCapabilityEvidence] = []
        for observation in observations {
            // Two reports about one client disagree about something. Which of
            // them is right is not a question a derivation can answer, and
            // picking one would be a guess with a record behind it.
            guard occurrences[observation.surface] == 1,
                observation.isCommandAvailable,
                let version = recordableVersion(observation.version)
            else { continue }
            records.append(skillRecord(observation, version: version, contract: adapterContractVersion))
            records.append(
                pluginRecord(
                    observation, version: version, contract: adapterContractVersion,
                    installRegister: installRegister))
            records.append(
                contentsOf: connectionRecords(observation, version: version, contract: adapterContractVersion))
        }
        return records.sorted { sortKey($0) < sortKey($1) }
    }
}

extension TargetCapabilityEvidence {
    /// Placing a skill is a file copy the capture layer already resolves a
    /// destination for, so what limits it is which scopes that client has
    /// folders for — which is what the adapter's own project-scope flag says.
    private static func skillRecord(
        _ observation: TargetObservation, version: String, contract: UInt
    ) -> TargetCapabilityEvidence {
        var scopes: [ToolingScope] = [.user]
        if observation.capabilities.supportsProjectScope { scopes.append(.project) }
        return .init(
            surface: observation.surface, installedClientVersion: version,
            adapterContractVersion: contract, component: .skill, scopes: ordered(scopes),
            support: .supported, observedAt: observation.lastScannedAt)
    }

    /// A package install is a command, and a command this Mac does not have
    /// written down cannot be run however willing the client is. Both halves
    /// have to hold: the adapter has to say the client installs packages of its
    /// own, and the register has to hold the command that does it.
    ///
    /// `WorkspaceNativePluginCommandPlanning` builds only the user-scoped
    /// command, so `.user` is the only scope claimed.
    private static func pluginRecord(
        _ observation: TargetObservation, version: String, contract: UInt,
        installRegister: NativePluginInstallSupport
    ) -> TargetCapabilityEvidence {
        let support: CapabilitySupport
        if !observation.capabilities.supportsPluginInstall {
            support = .unsupported(reason: "This app does not install packages of its own.")
        } else if !(observation.surface.client.map(installRegister.hasRecordedInstallCommand) ?? false) {
            support = .unsupported(
                reason: "Agent Tooling holds no recorded install command for this app, so nothing here could run one.")
        } else if pluginCommandClient(for: observation.surface) == nil {
            support = .unsupported(reason: "Agent Tooling has no reviewed package install route for this surface.")
        } else {
            support = .supported
        }
        return .init(
            surface: observation.surface, installedClientVersion: version,
            adapterContractVersion: contract, component: .plugin, scopes: [.user],
            support: support, observedAt: observation.lastScannedAt)
    }

    /// One record per transport `WorkspaceManagedMCPCommandPlanning` can
    /// actually spell for this client, at the scopes that client honours.
    ///
    /// A transport or a surface that planner refuses gets no record rather than
    /// an unsupported one: there is no version of this Mac where the missing
    /// command appears, so there is nothing for a person to act on.
    private static func connectionRecords(
        _ observation: TargetObservation, version: String, contract: UInt
    ) -> [TargetCapabilityEvidence] {
        guard let client = mcpCommandClient(for: observation.surface) else { return [] }
        let scopes = ordered(mcpScopes.filter { MCPClientCommand.supportsScope($0, client: client) })
        guard !scopes.isEmpty else { return [] }
        return MCPTransport.allCases.map { transport in
            .init(
                surface: observation.surface, installedClientVersion: version,
                adapterContractVersion: contract, component: .mcpServer, transport: transport.rawValue,
                scopes: scopes, support: .supported, observedAt: observation.lastScannedAt)
        }
    }

    /// The scopes the managed-MCP planner can produce a working directory for.
    /// It refuses managed, account and session outright for every client, so a
    /// record naming one would claim something no plan could ever use.
    private static let mcpScopes: [ToolingScope] = [.user, .project, .localProject, .workspace]

    /// `WorkspaceManagedMCPCommandPlanning`'s own surface switch.
    private static func mcpCommandClient(for surface: TargetSurface) -> ClientKind? {
        switch surface {
        case .claudeCode: .claude
        case .codexCLI: .codex
        case .geminiCLI: .gemini
        default: nil
        }
    }

    /// `WorkspaceNativePluginCommandPlanning`'s own surface switch, which is
    /// narrower: it has no Gemini case at all.
    private static func pluginCommandClient(for surface: TargetSurface) -> ClientKind? {
        switch surface {
        case .claudeCode: .claude
        case .codexCLI: .codex
        default: nil
        }
    }

    /// The exact string the captured target will carry, or nothing.
    ///
    /// A captured target's installed version is the observation's version, and
    /// the resolver matches the two for equality after checking the evidence's
    /// own copy is usable text. Recording anything but the observation's own
    /// spelling would produce evidence that can never match.
    private static func recordableVersion(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 256,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }

    /// Sorted the way the device state canonicalizes, so a derived list is
    /// already in its stored order and two runs over one scan are byte-identical.
    private static func ordered(_ scopes: [ToolingScope]) -> [ToolingScope] {
        scopes.sorted { $0.rawValue < $1.rawValue }
    }

    /// The same key `DeviceWorkspaceState.canonicalized()` sorts by, so storing
    /// a derived list never reorders it.
    private static func sortKey(_ evidence: TargetCapabilityEvidence) -> String {
        "\(evidence.surface.rawValue)|\(evidence.component.rawValue)|\(evidence.transport ?? "")"
            + "|\(evidence.adapterContractVersion)"
    }
}
