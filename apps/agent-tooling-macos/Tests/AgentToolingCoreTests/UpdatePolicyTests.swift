import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Update policy")
struct UpdatePolicyTests {
    @Test func theDefaultChecksOnOpenAndAsksBeforeInstallingAnything() {
        let policy = UpdatePolicy()
        #expect(policy.cadence == .onOpen)
        #expect(ToolingItemKind.allCases.allSatisfy { policy.policy(for: $0) == .ask })
        #expect(!policy.installsAnythingAutomatically)
    }

    @Test func eachKindIsSetOnItsOwnIncludingConnections() {
        var policy = UpdatePolicy()
        policy.setPolicy(.automatic, for: .mcpServer)
        #expect(policy.policy(for: .mcpServer) == .automatic)
        #expect(policy.policy(for: .skill) == .ask)
        #expect(policy.policy(for: .plugin) == .ask)
        #expect(policy.installsAnythingAutomatically)
    }

    @Test func cadenceDecidesWhenACheckIsDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hourAgo = now.addingTimeInterval(-3_600)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3_600)

        #expect(UpdateCheckCadence.onOpen.isDue(lastChecked: hourAgo, now: now))
        #expect(!UpdateCheckCadence.manual.isDue(lastChecked: nil, now: now))
        #expect(UpdateCheckCadence.daily.isDue(lastChecked: nil, now: now))
        #expect(!UpdateCheckCadence.daily.isDue(lastChecked: hourAgo, now: now))
        #expect(UpdateCheckCadence.daily.isDue(lastChecked: twoDaysAgo, now: now))
    }

    /// A device state written before the policy existed has no field for it,
    /// and must read as the default rather than fail to open.
    @Test func preferencesWrittenBeforeThePolicyExistedReadAsTheDefault() throws {
        let legacy = """
            {"automaticallyCheckHealth": true, "enabledClients": ["Claude Code"]}
            """
        let decoded = try AgentToolingCoding.decoder().decode(
            DeviceWorkspacePreferences.self, from: Data(legacy.utf8))
        #expect(decoded.updatePolicy == nil)
        #expect(decoded.effectiveUpdatePolicy == UpdatePolicy())
        #expect(decoded.lastUpdateCheck == nil)
    }

    @Test func aChosenPolicyRoundTrips() throws {
        var preferences = DeviceWorkspacePreferences()
        preferences.updatePolicy = UpdatePolicy(cadence: .daily, skills: .automatic, plugins: .ask, mcpServers: .automatic)
        preferences.lastUpdateCheck = Date(timeIntervalSince1970: 1_800_000_000)
        let bytes = try AgentToolingCoding.encoder().encode(preferences)
        let decoded = try AgentToolingCoding.decoder().decode(DeviceWorkspacePreferences.self, from: bytes)
        #expect(decoded == preferences)
    }
}
