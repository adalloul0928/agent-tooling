import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceAssignmentResolverTests {
    private var device: WorkspaceObjectID { objectID("00000000-0000-0000-0000-000000000001") }
    private var physical: WorkspaceObjectID { objectID("00000000-0000-0000-0000-000000000010") }
    private var skillID: ArtifactID { artifactID("00000000-0000-0000-0000-000000000101") }

    @Test func overlappingLogicalSurfacesProduceOnePhysicalRequirementWithIndependentReasons() throws {
        let first = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI, enabled: nil)
        let presetID = artifactID("00000000-0000-0000-0000-000000000201")
        let second = contribution(
            "00000000-0000-0000-0000-000000001002",
            surface: .codexDesktop,
            reason: .preset(presetID: presetID),
            enabled: true
        )
        let output = resolve(
            artifacts: [skill()],
            contributions: [second, first],
            targets: [target(.codexCLI), target(.codexDesktop)],
            evidence: [capability(.codexCLI), capability(.codexDesktop)],
            content: [content()]
        )

        let requirement = try #require(output.requirements.first)
        #expect(output.requirements.count == 1)
        #expect(requirement.desiredEnabled == true)
        #expect(requirement.contributions.map(\.id) == [first.id, second.id])
        #expect(requirement.contributions.map(\.destination.surface) == [.codexCLI, .codexDesktop])
        #expect(requirement.contributions.map(\.reason) == [.manual, .preset(presetID: presetID)])
    }

    @Test func opposingEnabledIntentBlocksThePhysicalRequirement() {
        let yes = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI, enabled: true)
        let no = contribution("00000000-0000-0000-0000-000000001002", surface: .codexDesktop, enabled: false)
        let output = resolve(
            artifacts: [skill()], contributions: [yes, no],
            targets: [target(.codexCLI), target(.codexDesktop)],
            evidence: [capability(.codexCLI), capability(.codexDesktop)], content: [content()]
        )
        #expect(output.requirements.isEmpty)
        #expect(output.issues.contains { $0.kind == .conflictingEnabledIntent && $0.contributionIDs == [yes.id, no.id] })
    }

    @Test func blockedSharedTargetCannotLeakARequirementWhileAnotherPhysicalTargetRemainsIndependent() throws {
        let enabled = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI, enabled: true)
        let disabledUnknown = contribution(
            "00000000-0000-0000-0000-000000001002", surface: .claudeCode, enabled: false
        )
        let independent = contribution("00000000-0000-0000-0000-000000001003", surface: .geminiCLI)
        let otherPhysical = objectID("00000000-0000-0000-0000-000000000011")
        let output = resolve(
            artifacts: [skill()], contributions: [enabled, disabledUnknown, independent],
            targets: [
                target(.codexCLI), target(.claudeCode), target(.geminiCLI, physicalID: otherPhysical),
            ],
            evidence: [
                capability(.codexCLI), capability(.claudeCode, support: .unknown(reason: "not probed")),
                capability(.geminiCLI),
            ],
            content: [content()]
        )
        #expect(output.issues.contains { $0.kind == .conflictingEnabledIntent && $0.physicalDestinationID == physical })
        #expect(output.issues.contains { $0.kind == .unknownCapability && $0.physicalDestinationID == physical })
        let requirement = try #require(output.requirements.first)
        #expect(output.requirements.count == 1)
        #expect(requirement.physicalDestinationID == otherPhysical)
        #expect(requirement.contributions == [independent])
    }

    @Test func nilEnabledRemainsNil() throws {
        let value = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI, enabled: nil)
        let output = resolve(
            artifacts: [skill()], contributions: [value], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)], content: [content()]
        )
        #expect(try #require(output.requirements.first).desiredEnabled == nil)
    }

    @Test func deviceSelectorsDistinguishAllNoneCurrentAndOther() {
        let all = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI, deviceIDs: nil)
        let none = contribution("00000000-0000-0000-0000-000000001002", surface: .codexCLI, deviceIDs: [])
        let current = contribution("00000000-0000-0000-0000-000000001003", surface: .codexCLI, deviceIDs: [device])
        let other = contribution(
            "00000000-0000-0000-0000-000000001004", surface: .codexCLI,
            deviceIDs: [objectID("00000000-0000-0000-0000-000000000099")]
        )
        let output = resolve(
            artifacts: [skill()], contributions: [other, none, current, all], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)], content: [content()]
        )
        #expect(output.requirements.first?.contributions.map(\.id) == [all.id, current.id])
        #expect(output.ignoredContributionIDs == [none.id, other.id])
    }

    @Test func nativeRootSelectsTheConsumingClientRoute() throws {
        let nativeID = artifactID("00000000-0000-0000-0000-000000000102")
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: nativeID, surface: .claudeCode
        )
        let artifact = nativePlugin(nativeID, routes: [
            .init(client: .claude, externalPluginID: "claude-plugin"),
            .init(client: .codex, externalPluginID: "codex-plugin"),
        ])
        let output = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.claudeCode, component: .plugin)],
            evidence: [capability(.claudeCode, component: .plugin)]
        )
        let strategy = try #require(output.requirements.first?.strategy)
        #expect(strategy == .nativePlugin(route: .init(client: .claude, externalPluginID: "claude-plugin")))
    }

    @Test func nativeChildAndMissingRouteAreBlockedWithoutRedirection() {
        let parentID = artifactID("00000000-0000-0000-0000-000000000102")
        let childID = artifactID("00000000-0000-0000-0000-000000000103")
        let child = ArtifactRecord(
            identity: .init(id: childID, kind: .skill, displayName: "child", parentPackageID: parentID),
            authority: .nativeOwned
        )
        let childAssignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: childID, surface: .codexCLI
        )
        let rootAssignment = contribution(
            "00000000-0000-0000-0000-000000001002", artifactID: parentID, surface: .codexCLI
        )
        let output = resolve(
            artifacts: [child, nativePlugin(parentID, routes: [.init(client: .claude, externalPluginID: "only-claude")])],
            contributions: [childAssignment, rootAssignment],
            targets: [.init(
                selector: .init(surface: .codexCLI, scope: .user), physicalDestinationID: physical,
                installedClientVersion: "1.0", adapterContractVersion: 7,
                componentContexts: [.init(component: .skill), .init(component: .plugin)]
            )],
            evidence: [capability(.codexCLI), capability(.codexCLI, component: .plugin)]
        )
        #expect(output.requirements.isEmpty)
        #expect(output.issues.contains { $0.kind == .nativeChildAssignment && $0.artifactID == childID })
        #expect(output.issues.contains { $0.kind == .missingNativeRoute && $0.artifactID == parentID })
    }

    @Test func malformedNativeRouteDoesNotBecomeAPlanningFact() {
        let nativeID = artifactID("00000000-0000-0000-0000-000000000102")
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: nativeID, surface: .codexCLI
        )
        let output = resolve(
            artifacts: [nativePlugin(nativeID, routes: [.init(client: .codex, externalPluginID: "")])],
            contributions: [assignment], targets: [target(.codexCLI, component: .plugin)],
            evidence: [capability(.codexCLI, component: .plugin)]
        )
        #expect(output.requirements.isEmpty)
        #expect(output.issues.contains { $0.kind == .invalidNativeRoute })
    }

    @Test func incompatibleNativeRoutesSharingOnePhysicalTargetBlock() {
        let nativeID = artifactID("00000000-0000-0000-0000-000000000102")
        let claude = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: nativeID, surface: .claudeCode
        )
        let codex = contribution(
            "00000000-0000-0000-0000-000000001002", artifactID: nativeID, surface: .codexCLI
        )
        let output = resolve(
            artifacts: [nativePlugin(nativeID, routes: [
                .init(client: .claude, externalPluginID: "claude-id"),
                .init(client: .codex, externalPluginID: "codex-id"),
            ])],
            contributions: [claude, codex],
            targets: [target(.claudeCode, component: .plugin), target(.codexCLI, component: .plugin)],
            evidence: [capability(.claudeCode, component: .plugin), capability(.codexCLI, component: .plugin)]
        )
        #expect(output.requirements.isEmpty)
        #expect(output.issues.contains { $0.kind == .incompatiblePhysicalStrategies })
    }

    @Test func duplicateContributionsTargetsAndEvidenceNeverUseFirstWins() {
        let duplicate = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI)
        let targetBlocked = contribution("00000000-0000-0000-0000-000000001002", surface: .codexDesktop)
        let evidenceBlocked = contribution("00000000-0000-0000-0000-000000001003", surface: .claudeCode)
        let duplicateTarget = target(.codexDesktop)
        let duplicateEvidence = capability(.claudeCode)
        let output = resolve(
            artifacts: [skill()],
            contributions: [duplicate, duplicate, targetBlocked, evidenceBlocked],
            targets: [target(.codexCLI), duplicateTarget, duplicateTarget, target(.claudeCode)],
            evidence: [capability(.codexCLI), capability(.codexDesktop), duplicateEvidence, duplicateEvidence],
            content: [content()]
        )
        #expect(output.requirements.isEmpty)
        #expect(output.issues.contains { $0.kind == .duplicateContributionID })
        #expect(output.issues.contains { $0.kind == .duplicateResolvedTarget })
        #expect(output.issues.contains { $0.kind == .contradictoryCapabilityEvidence })
    }

    @Test func capabilityMatchingRequiresExactVersionContractComponentTransportAndScope() {
        let assignment = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI)
        let mismatched = capability(.codexCLI, version: "2.0", contract: 8)
        let output = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI, version: "1.0", contract: 7)],
            evidence: [mismatched], content: [content()]
        )
        #expect(output.requirements.isEmpty)
        #expect(output.issues.contains { $0.kind == .missingCapabilityEvidence })

        let unsupported = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI, support: .unsupported(reason: "adapter does not support this"))], content: [content()]
        )
        #expect(unsupported.issues.contains { $0.kind == .unsupportedCapability })

        let unknown = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI, support: .unknown(reason: "not probed"))], content: [content()]
        )
        #expect(unknown.issues.contains { $0.kind == .unknownCapability })
    }

    @Test func mcpRequiresExplicitTransportDefinitionAndExactCapability() throws {
        let mcpID = artifactID("00000000-0000-0000-0000-000000000104")
        let artifact = ArtifactRecord(
            identity: .init(id: mcpID, kind: .mcpServer, displayName: "server"),
            authority: .centralPersonal,
            contentDigest: digest()
        )
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: mcpID, surface: .codexCLI
        )
        let missing = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: "stdio")],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: "stdio")],
            content: [.init(artifactID: mcpID, digest: digest())]
        )
        #expect(missing.issues.contains { $0.kind == .missingMCPDefinition })

        let supported = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: "stdio")],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: "stdio")],
            definitions: [.init(artifactID: mcpID, transport: "stdio")],
            content: [.init(artifactID: mcpID, digest: digest())]
        )
        #expect(try #require(supported.requirements.first).transport == "stdio")
    }

    @Test func managedRemoteMCPUsesTypedDefinitionWithoutInventingContent() throws {
        let mcpID = artifactID("00000000-0000-0000-0000-000000000105")
        let artifact = managedMCP(mcpID)
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: mcpID, surface: .codexCLI)
        let definition = PortableMCPDefinitionRecord(
            artifactID: mcpID, connection: .remoteHTTPS(url: "https://mcp.example.com/v1"))
        let output = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            portableDefinitions: [definition])

        let requirement = try #require(output.requirements.first)
        #expect(output.issues.isEmpty)
        #expect(requirement.transport == MCPTransport.http.rawValue)
        #expect(requirement.strategy == .managedMCP(definition: definition, deviceBinding: nil))
    }

    @Test func managedStdioMCPRequiresExactDeviceDestination() throws {
        let mcpID = artifactID("00000000-0000-0000-0000-000000000105")
        let artifact = managedMCP(mcpID)
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: mcpID, surface: .codexCLI)
        let definition = PortableMCPDefinitionRecord(
            artifactID: mcpID, connection: .deviceBound(transport: .stdio))
        let binding = DeviceMCPDefinitionBinding(
            artifactID: mcpID,
            destination: .stdio(executable: "mcp-runner", arguments: ["--label", "two words"]))
        let output = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            portableDefinitions: [definition], deviceBindings: [binding])

        #expect(output.issues.isEmpty)
        #expect(try #require(output.requirements.first).strategy == .managedMCP(
            definition: definition, deviceBinding: binding))

        let missing = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            portableDefinitions: [definition])
        #expect(missing.requirements.isEmpty)
        #expect(missing.issues.contains { $0.kind == .missingDeviceMCPBinding })
    }

    @Test func managedWorkspaceMCPRequiresCapturedWorkspaceRoot() throws {
        let mcpID = artifactID("00000000-0000-0000-0000-000000000105")
        let artifact = managedMCP(mcpID)
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001",
            artifactID: mcpID,
            surface: .codexCLI,
            scope: .workspace
        )
        let definition = PortableMCPDefinitionRecord(
            artifactID: mcpID, connection: .remoteHTTPS(url: "https://mcp.example.com/v1"))
        let missingRoot = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(
                .codexCLI, scope: .workspace, component: .mcpServer,
                transport: MCPTransport.http.rawValue)],
            evidence: [capability(
                .codexCLI, scope: .workspace, component: .mcpServer,
                transport: MCPTransport.http.rawValue)],
            portableDefinitions: [definition])
        #expect(missingRoot.requirements.isEmpty)
        #expect(missingRoot.issues.contains { $0.kind == .missingDeviceMCPBinding })

        let binding = DeviceMCPDefinitionBinding(
            artifactID: mcpID, workspaceRootPath: "/workspace/project")
        let capturedRoot = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(
                .codexCLI, scope: .workspace, component: .mcpServer,
                transport: MCPTransport.http.rawValue)],
            evidence: [capability(
                .codexCLI, scope: .workspace, component: .mcpServer,
                transport: MCPTransport.http.rawValue)],
            portableDefinitions: [definition], deviceBindings: [binding])
        #expect(capturedRoot.issues.isEmpty)
        #expect(capturedRoot.requirements.count == 1)
    }

    @Test func managedMCPRejectsMalformedBindingAndContradictoryTransportEvidence() {
        let mcpID = artifactID("00000000-0000-0000-0000-000000000105")
        let artifact = managedMCP(mcpID)
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: mcpID, surface: .codexCLI)
        let definition = PortableMCPDefinitionRecord(
            artifactID: mcpID, connection: .deviceBound(transport: .stdio))
        let malformed = DeviceMCPDefinitionBinding(
            artifactID: mcpID,
            destination: .stdio(executable: "runner", arguments: ["--token", "secret"]))
        let invalid = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            portableDefinitions: [definition], deviceBindings: [malformed])
        #expect(invalid.requirements.isEmpty)
        #expect(invalid.issues.contains { $0.kind == .invalidDeviceMCPBinding })

        let binding = DeviceMCPDefinitionBinding(
            artifactID: mcpID, destination: .stdio(executable: "runner", arguments: []))
        let contradictory = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.stdio.rawValue)],
            definitions: [.init(artifactID: mcpID, transport: MCPTransport.http.rawValue)],
            portableDefinitions: [definition], deviceBindings: [binding])
        #expect(contradictory.requirements.isEmpty)
        #expect(contradictory.issues.contains { $0.kind == .contradictoryMCPDefinition })
    }

    @Test func malformedOrDuplicateManagedDefinitionsDoNotUseFirstWins() {
        let mcpID = artifactID("00000000-0000-0000-0000-000000000105")
        let artifact = managedMCP(mcpID)
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", artifactID: mcpID, surface: .codexCLI)
        let malformed = PortableMCPDefinitionRecord(
            artifactID: mcpID, connection: .remoteHTTPS(url: "https://localhost/mcp"))
        let invalid = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            portableDefinitions: [malformed])
        #expect(invalid.issues.contains { $0.kind == .invalidManagedMCPDefinition })

        let valid = PortableMCPDefinitionRecord(
            artifactID: mcpID, connection: .remoteHTTPS(url: "https://mcp.example.com"))
        let duplicate = resolve(
            artifacts: [artifact], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            portableDefinitions: [valid, valid])
        #expect(duplicate.requirements.isEmpty)
        #expect(duplicate.issues.contains { $0.kind == .ambiguousMCPDefinition })

        let artifactWithPackageBytes = ArtifactRecord(
            identity: artifact.identity,
            authority: .centralPersonal,
            contentDigest: digest()
        )
        let wrongAuthorityShape = resolve(
            artifacts: [artifactWithPackageBytes], contributions: [assignment],
            targets: [target(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            evidence: [capability(.codexCLI, component: .mcpServer, transport: MCPTransport.http.rawValue)],
            portableDefinitions: [valid])
        #expect(wrongAuthorityShape.requirements.isEmpty)
        #expect(wrongAuthorityShape.issues.contains { $0.kind == .invalidManagedMCPDefinition })
    }

    @Test func trackedOwnershipAndUncapturedOrMismatchedContentRemainBlocked() {
        let assignment = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI)
        let tracked = resolve(
            artifacts: [skill(authority: .trackedOnly)], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)], content: [content()]
        )
        #expect(tracked.issues.contains { $0.kind == .trackedOnlyOwnership })

        let missing = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)]
        )
        #expect(missing.issues.contains { $0.kind == .missingMaterializedContent })

        let wrong = AssignmentContentEvidence(
            artifactID: skillID,
            digest: .init(value: String(repeating: "b", count: 64))
        )
        let mismatched = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)], content: [wrong]
        )
        #expect(mismatched.issues.contains { $0.kind == .missingMaterializedContent })

        let duplicated = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)], content: [content(), content()]
        )
        #expect(duplicated.issues.contains { $0.kind == .ambiguousContentEvidence })

        let malformedDigest = ContentDigest(value: "not-a-digest")
        let malformedArtifact = ArtifactRecord(
            identity: .init(id: skillID, kind: .skill, displayName: "skill"),
            authority: .centralPersonal,
            contentDigest: malformedDigest
        )
        let malformed = resolve(
            artifacts: [malformedArtifact], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)],
            content: [.init(artifactID: skillID, digest: malformedDigest)]
        )
        #expect(malformed.requirements.isEmpty)
        #expect(malformed.issues.contains { $0.kind == .missingMaterializedContent })
    }

    @Test func presetReasonRemainsOneExplicitApplyOnceContribution() throws {
        let presetID = artifactID("00000000-0000-0000-0000-000000000201")
        let assignment = contribution(
            "00000000-0000-0000-0000-000000001001", surface: .codexCLI,
            reason: .preset(presetID: presetID)
        )
        let output = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)], content: [content()]
        )
        let values = try #require(output.requirements.first?.contributions)
        #expect(values == [assignment])
        #expect(values.first?.reason == .preset(presetID: presetID))
    }

    @Test func falsePresenceIsInvalidAndDoesNotPlanRemoval() {
        var assignment = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI)
        assignment.desiredPresence = false
        let output = resolve(
            artifacts: [skill()], contributions: [assignment], targets: [target(.codexCLI)],
            evidence: [capability(.codexCLI)], content: [content()]
        )
        #expect(output.requirements.isEmpty)
        #expect(output.issues.contains { $0.kind == .invalidDesiredPresence })
    }

    @Test func shuffledInputsProduceIdenticalOutput() {
        let first = contribution("00000000-0000-0000-0000-000000001001", surface: .codexCLI)
        let second = contribution("00000000-0000-0000-0000-000000001002", surface: .codexDesktop)
        let targets = [target(.codexCLI), target(.codexDesktop)]
        let evidence = [capability(.codexCLI), capability(.codexDesktop)]
        let forward = resolve(
            artifacts: [skill()], contributions: [first, second], targets: targets,
            evidence: evidence, content: [content()]
        )
        let reverse = resolve(
            artifacts: [skill()], contributions: [second, first], targets: Array(targets.reversed()),
            evidence: Array(evidence.reversed()), content: [content()]
        )
        #expect(forward == reverse)
    }

    private func resolve(
        artifacts: [ArtifactRecord], contributions: [AssignmentContribution],
        targets: [ResolvedAssignmentTarget], evidence: [TargetCapabilityEvidence],
        definitions: [MCPAssignmentDefinitionEvidence] = [], content: [AssignmentContentEvidence] = [],
        portableDefinitions: [PortableMCPDefinitionRecord] = [],
        deviceBindings: [DeviceMCPDefinitionBinding] = []
    ) -> WorkspaceAssignmentResolution {
        WorkspaceAssignmentResolver.resolve(
            artifacts: artifacts, contributions: contributions, currentDeviceID: device,
            targets: targets, capabilityEvidence: evidence, mcpDefinitions: definitions, contentEvidence: content,
            portableMCPDefinitions: portableDefinitions, deviceMCPBindings: deviceBindings
        )
    }

    private func contribution(
        _ id: String, artifactID: ArtifactID? = nil, surface: TargetSurface,
        reason: AssignmentReason = .manual, enabled: Bool? = nil,
        deviceIDs: [WorkspaceObjectID]? = nil, scope: ToolingScope = .user
    ) -> AssignmentContribution {
        .init(
            id: objectID(id), artifactID: artifactID ?? skillID,
            destination: .init(surface: surface, scope: scope, deviceIDs: deviceIDs),
            reason: reason, desiredEnabled: enabled
        )
    }

    private func skill(authority: ContentAuthority = .centralPersonal) -> ArtifactRecord {
        .init(
            identity: .init(id: skillID, kind: .skill, displayName: "skill"),
            authority: authority,
            contentDigest: digest()
        )
    }

    private func nativePlugin(_ id: ArtifactID, routes: [NativePackageRoute]) -> ArtifactRecord {
        .init(
            identity: .init(id: id, kind: .nativePlugin, displayName: "plugin"),
            authority: .nativeOwned,
            nativeRoutes: routes
        )
    }

    private func managedMCP(_ id: ArtifactID) -> ArtifactRecord {
        .init(
            identity: .init(id: id, kind: .mcpServer, displayName: "managed MCP"),
            authority: .centralPersonal)
    }

    private func target(
        _ surface: TargetSurface, scope: ToolingScope = .user,
        component: ComponentKind = .skill, transport: String? = nil,
        version: String = "1.0", contract: UInt = 7, physicalID: WorkspaceObjectID? = nil
    ) -> ResolvedAssignmentTarget {
        .init(
            selector: .init(surface: surface, scope: scope),
            physicalDestinationID: physicalID ?? physical,
            installedClientVersion: version,
            adapterContractVersion: contract,
            componentContexts: [.init(component: component, transport: transport)]
        )
    }

    private func capability(
        _ surface: TargetSurface, scope: ToolingScope = .user,
        component: ComponentKind = .skill, transport: String? = nil,
        version: String = "1.0", contract: UInt = 7,
        support: CapabilitySupport = .supported
    ) -> TargetCapabilityEvidence {
        .init(
            surface: surface, installedClientVersion: version, adapterContractVersion: contract,
            component: component, transport: transport, scopes: [scope], support: support,
            observedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func content() -> AssignmentContentEvidence {
        .init(artifactID: skillID, digest: digest())
    }

    private func digest() -> ContentDigest {
        .init(value: String(repeating: "a", count: 64))
    }

    private func artifactID(_ value: String) -> ArtifactID {
        ArtifactID(UUID(uuidString: value)!)
    }

    private func objectID(_ value: String) -> WorkspaceObjectID {
        WorkspaceObjectID(UUID(uuidString: value)!)
    }
}
