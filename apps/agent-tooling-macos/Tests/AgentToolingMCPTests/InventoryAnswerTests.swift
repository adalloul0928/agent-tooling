import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingMCP

/// What the server answers inventory questions from.
///
/// There is one store and no second one to fall back to, so the questions this
/// file used to ask — which library answered — no longer exist. What remains is
/// the claim that outlives them: a workspace records what a person *asked for*,
/// and an ask is never reported as a measurement.
@Suite("Inventory answers")
struct InventoryAnswerTests {
    @Test func anItemInTheLibraryCanBeFoundAndFetched() throws {
        let harness = try MCPTestHarness(artifacts: [Self.skill("Release summary", "release-summary")])
        try harness.initialize()

        let search = try harness.callTool("search_inventory", arguments: ["query": .string("")])
        #expect((search["results"]?.arrayValue ?? []).compactMap { $0.objectValue?["name"]?.stringValue }
            == ["Release summary"])

        let component = try harness.callTool("get_component", arguments: [
            "kind": .string("skill"), "id": .string(harness.identifier(of: "release-summary")),
        ])
        #expect(component["name"]?.stringValue == "Release summary")
    }

    @Test func somethingTheLibraryDoesNotHoldSaysSoRatherThanInventingARecord() throws {
        let harness = try MCPTestHarness(artifacts: [Self.skill("Release summary", "release-summary")])
        try harness.initialize()

        let missing = try #require(harness.rawCallTool("get_component", arguments: [
            "kind": .string("skill"), "id": .string("nothing-by-that-name"),
        ]))

        #expect(missing["result"]?.objectValue?["isError"]?.boolValue == true)
    }

    @Test func aRequestedDestinationIsReportedAsRequestedNotAsInstalled() throws {
        let skill = Self.skill("Release summary", "release-summary")
        let harness = try MCPTestHarness(
            artifacts: [skill],
            assignments: [.init(artifactID: skill.identity.id,
                                destination: .init(surface: .codexCLI, scope: .user),
                                reason: .manual)])
        try harness.initialize()

        let component = try harness.callTool("get_component", arguments: [
            "kind": .string("skill"), "id": .string(harness.identifier(of: "release-summary")),
        ])

        let client = try #require(component["clients"]?.arrayValue?.first?.objectValue)
        #expect(client["client"]?.stringValue == "codex")
        #expect(client["state"]?.stringValue == "pending")
        // The field an agent would read as "it is there".
        #expect(client["installed"]?.boolValue == false)
    }

    @Test func receiptsAndObservationsComeFromTheSameStoreAsTheItems() throws {
        let harness = try MCPTestHarness(
            artifacts: [Self.skill("Release summary", "release-summary")],
            observations: [.init(surface: .codexCLI, installed: true, commandAvailable: true,
                                 version: "1.0.0",
                                 capabilities: .init(supportsPluginInstall: false, supportsProjectScope: true,
                                                     supportsLocalMarketplace: false,
                                                     supportsMCPAuthentication: false,
                                                     supportsConnectorDiscovery: false,
                                                     requiresNewSession: true, requiresRestart: false,
                                                     supportsMachineReadableOutput: true),
                                 lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))],
            receipts: [.init(planID: UUID(), kind: .installSkill, title: "Installed something",
                             state: .healthy, targetSurfaces: [.codexCLI], results: [],
                             createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             verificationSummary: "Verified in place.")])
        try harness.initialize()

        // Nothing is left for a second store to supply.
        #expect(try harness.callTool("get_client_status")["clients"]?.arrayValue?.count == 1)
        #expect(try harness.callTool("list_receipts")["receipts"]?.arrayValue?.count == 1)
    }

    private static func skill(_ displayName: String, _ declaredName: String) -> ArtifactRecord {
        .init(identity: .init(id: ArtifactID(), kind: .skill, displayName: displayName),
              authority: .centralPersonal, declaredName: declaredName,
              contentDigest: .init(value: String(repeating: "a", count: 64)))
    }
}
