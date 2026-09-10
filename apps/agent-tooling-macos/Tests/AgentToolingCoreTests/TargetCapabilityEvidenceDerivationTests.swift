import Foundation
import Testing

@testable import AgentToolingCore

/// What this Mac's scan says each client can be asked to carry.
///
/// Every record here has to be one the resolver and the two command planners
/// would accept: they require exactly one match on surface, version, adapter
/// contract, component, transport and scope, so a duplicate blocks rather than
/// allows, and a record for something no planner can express is a claim with
/// nothing behind it.
@Suite("Target capability evidence derivation")
struct TargetCapabilityEvidenceDerivationTests {
    @Test func eachSurfaceComponentAndTransportGetsExactlyOneRecord() {
        let evidence = TargetCapabilityEvidence.derive(
            from: [Self.observation(.claudeCode), Self.observation(.codexCLI)])

        let keys = evidence.map { Key($0) }
        #expect(Set(keys).count == keys.count, "\(keys)")
        // Skill, plugin, and one connection record per transport, per client.
        #expect(evidence.count == 8)
        #expect(
            Set(evidence.filter { $0.component == .mcpServer }.map(\.transport))
                == ["HTTP", "stdio"])
        #expect(evidence.allSatisfy { $0.adapterContractVersion == WorkspaceSkillTargetCapture.adapterContractVersion })
    }

    @Test func theVersionIsTheOneTheScanReported() throws {
        // A captured target carries the observation's own version string, and
        // the resolver matches the two for equality. Anything but the exact
        // spelling produces evidence that can never match.
        let reported = "2.1.263 (Claude Code)"
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let evidence = TargetCapabilityEvidence.derive(
            from: [Self.observation(.claudeCode, version: reported, scannedAt: scannedAt)])

        #expect(evidence.allSatisfy { $0.installedClientVersion == reported })
        #expect(evidence.allSatisfy { $0.observedAt == scannedAt })
        let target = Self.target(.claudeCode, version: reported, evidence: evidence)
        #expect(evidence.contains { $0.installedClientVersion == target.installedClientVersion })
    }

    @Test func skillScopesFollowWhatTheAdapterSaysAboutProjects() throws {
        let withProjects = TargetCapabilityEvidence.derive(
            from: [Self.observation(.claudeCode, projectScope: true)])
        let userOnly = TargetCapabilityEvidence.derive(
            from: [Self.observation(.claudeCode, projectScope: false)])

        #expect(try Self.record(withProjects, .skill).scopes == [.project, .user])
        #expect(try Self.record(userOnly, .skill).scopes == [.user])
    }

    @Test func aPackageInstallNeedsBothTheAdapterAndARecordedCommand() throws {
        // Gemini's adapter says it installs packages of its own, but nobody has
        // read a command out of its help, so the register holds none.
        let gemini = try Self.record(
            TargetCapabilityEvidence.derive(from: [Self.observation(.geminiCLI)]), .plugin)
        guard case .unsupported(let reason) = gemini.support else {
            Issue.record("Gemini claimed package support with no recorded command: \(gemini.support)")
            return
        }
        #expect(reason.contains("recorded install command"))
        #expect(NativePluginInstallRegister.command(for: .gemini, externalPluginID: "browser") == nil)

        // A client whose adapter does not install packages is unsupported even
        // where a command exists.
        let noAdapterSupport = try Self.record(
            TargetCapabilityEvidence.derive(
                from: [Self.observation(.claudeCode, pluginInstall: false)]), .plugin)
        #expect(noAdapterSupport.support != .supported)

        // And a register with nothing written down for this client refuses it
        // however willing the adapter is.
        let noCommand = try Self.record(
            TargetCapabilityEvidence.derive(
                from: [Self.observation(.claudeCode)],
                installRegister: .init { _ in false }), .plugin)
        #expect(noCommand.support != .supported)

        for surface in [TargetSurface.claudeCode, .codexCLI] {
            let record = try Self.record(
                TargetCapabilityEvidence.derive(from: [Self.observation(surface)]), .plugin)
            #expect(record.support == .supported, "\(surface) \(record.support)")
            // The plugin planner builds only the user-scoped command.
            #expect(record.scopes == [.user])
        }
    }

    @Test func connectionScopesAndTransportsAreTheOnesTheCommandPlannerCanSpell() throws {
        let claude = TargetCapabilityEvidence.derive(from: [Self.observation(.claudeCode)])
            .filter { $0.component == .mcpServer }
        let codex = TargetCapabilityEvidence.derive(from: [Self.observation(.codexCLI)])
            .filter { $0.component == .mcpServer }

        // Codex's MCP command exposes no scope flag, so anything but user is
        // refused before it reaches a command.
        #expect(codex.allSatisfy { $0.scopes == [.user] })
        #expect(claude.allSatisfy { $0.scopes == [.localProject, .project, .user, .workspace] })
        for record in claude + codex {
            let client = try #require(record.surface.client)
            #expect(record.scopes.allSatisfy { MCPClientCommand.supportsScope($0, client: client) })
            // Managed, account and session have no working directory the
            // planner will produce, for any client.
            #expect(!record.scopes.contains { [.managed, .account, .session].contains($0) })
        }
        #expect(Set(claude.map(\.transport)) == Set(MCPTransport.allCases.map { $0.rawValue as String? }))

        // A surface with no command bridge of its own gets no connection record.
        let desktop = TargetCapabilityEvidence.derive(from: [Self.observation(.claudeDesktop)])
        #expect(!desktop.contains { $0.component == .mcpServer })
    }

    @Test func nothingIsRecordedForConnectorsOrForTheComponentsNoPlannerCarries() {
        let evidence = TargetCapabilityEvidence.derive(from: [Self.observation(.claudeCode)])

        #expect(Set(evidence.map(\.component)) == [.skill, .plugin, .mcpServer])
    }

    @Test func aClientThatDidNotAnswerProducesNoRecordAtAll() {
        // Unknown never becomes an actionable install claim: the planner's
        // existing "no dependable record" exclusion is the honest outcome.
        #expect(
            TargetCapabilityEvidence.derive(
                from: [Self.observation(.claudeCode, version: nil)]).isEmpty)
        #expect(
            TargetCapabilityEvidence.derive(
                from: [Self.observation(.claudeCode, version: "")]).isEmpty)
        #expect(
            TargetCapabilityEvidence.derive(
                from: [Self.observation(.claudeCode, commandAvailable: false)]).isEmpty)
        #expect(TargetCapabilityEvidence.derive(from: []).isEmpty)

        // Two reports about one client disagree about something; picking one
        // would be a guess with a record behind it.
        let contradictory = TargetCapabilityEvidence.derive(from: [
            Self.observation(.claudeCode, version: "1.0.0"),
            Self.observation(.claudeCode, version: "2.0.0"),
            Self.observation(.codexCLI),
        ])
        #expect(!contradictory.contains { $0.surface == .claudeCode })
        #expect(contradictory.contains { $0.surface == .codexCLI })
    }

    @Test func theResultIsSortedDeterministicAndValidDeviceState() throws {
        let observations = [
            Self.observation(.geminiCLI), Self.observation(.claudeCode), Self.observation(.codexCLI),
        ]
        let evidence = TargetCapabilityEvidence.derive(from: observations)

        #expect(evidence == TargetCapabilityEvidence.derive(from: observations))
        var device = DeviceWorkspaceState(workspaceID: WorkspaceObjectID())
        device.observations = observations
        device.capabilityEvidence = evidence
        #expect(throws: Never.self) { try device.validateStructure() }
        // Storing it must not reorder it, or two equal scans would produce two
        // different device records.
        #expect(device.canonicalized().capabilityEvidence == evidence)
    }

    @Test func anAssignedSkillBecomesAnInstallStepRatherThanAnExcludedOne() throws {
        let observation = Self.observation(.claudeCode, version: "2.1.263 (Claude Code)")
        let document = try Self.document()

        // What shipped before this existed: nothing wrote capability evidence,
        // so every destination was refused for the want of a record.
        var blind = DeviceWorkspaceState(workspaceID: Self.workspaceID, deviceID: Self.deviceID)
        blind.observations = [observation]
        let refused = WorkspaceDeploymentPlanner.plan(
            document: document, device: blind,
            targets: [Self.target(.claudeCode, version: observation.version, evidence: [])],
            availableContent: [.init(artifactID: Self.skillID, digest: Self.digest)])
        #expect(refused.items.isEmpty)
        #expect(refused.exclusions.map(\.reason) == [.unsupportedByAdapter])

        var device = blind
        device.capabilityEvidence = TargetCapabilityEvidence.derive(from: [observation])
        let plan = WorkspaceDeploymentPlanner.plan(
            document: document, device: device,
            targets: [
                Self.target(
                    .claudeCode, version: observation.version,
                    evidence: device.capabilityEvidence)
            ],
            availableContent: [.init(artifactID: Self.skillID, digest: Self.digest)])

        #expect(plan.exclusions.isEmpty, "\(plan.exclusions)")
        #expect(plan.items.map(\.action) == [.installContent(digest: Self.digest)])
        #expect(plan.items.first?.surface == .claudeCode)
        #expect(plan.items.first?.artifactID == Self.skillID)
    }

    private struct Key: Hashable {
        let surface: TargetSurface
        let component: ComponentKind
        let transport: String?

        init(_ evidence: TargetCapabilityEvidence) {
            surface = evidence.surface
            component = evidence.component
            transport = evidence.transport
        }
    }

    private static let skillID = ArtifactID()
    private static let deviceID = WorkspaceObjectID()
    private static let workspaceID = WorkspaceObjectID()
    private static let destinationID = WorkspaceObjectID()
    private static let contributionID = WorkspaceObjectID()
    private static let digest = ContentDigest(algorithm: .sha256TreeV1, value: String(repeating: "a", count: 64))

    private static func record(
        _ evidence: [TargetCapabilityEvidence], _ component: ComponentKind
    ) throws -> TargetCapabilityEvidence {
        let matches = evidence.filter { $0.component == component }
        #expect(matches.count == 1, "\(component): \(matches.count) records")
        return try #require(matches.first)
    }

    private static func observation(
        _ surface: TargetSurface,
        version: String? = "1.0.0",
        commandAvailable: Bool = true,
        projectScope: Bool = true,
        pluginInstall: Bool = true,
        scannedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TargetObservation {
        .init(
            surface: surface, installed: true, commandAvailable: commandAvailable, version: version,
            capabilities: .init(
                supportsPluginInstall: pluginInstall, supportsProjectScope: projectScope,
                supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                supportsConnectorDiscovery: false, requiresNewSession: false, requiresRestart: false,
                supportsMachineReadableOutput: true),
            lastScannedAt: scannedAt)
    }

    /// A destination captured the way the capture layer captures one: the
    /// observation's own version, this build's adapter contract, and the
    /// component contexts that same layer derives from the evidence.
    private static func target(
        _ surface: TargetSurface, version: String?, evidence: [TargetCapabilityEvidence]
    ) -> ResolvedAssignmentTarget {
        .init(
            selector: .init(surface: surface, scope: .user, logicalProjectID: nil),
            physicalDestinationID: destinationID,
            installedClientVersion: version,
            adapterContractVersion: WorkspaceSkillTargetCapture.adapterContractVersion,
            componentContexts: WorkspaceSkillTargetCapture.componentContexts(
                surface: surface, scope: .user, version: version, evidence: evidence))
    }

    private static func document() throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: workspaceID, revision: .init(writerID: deviceID),
                artifacts: [
                    .init(
                        identity: .init(id: skillID, kind: .skill, displayName: "Personal"),
                        authority: .centralPersonal, declaredName: "personal", contentDigest: digest)
                ],
                assignments: [
                    .init(
                        id: contributionID, artifactID: skillID,
                        destination: .init(surface: .claudeCode, scope: .user),
                        reason: .manual, desiredPresence: true)
                ]))
    }
}
