import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// What this Mac tells the others each app holds leaves out Agent Tooling's
/// own connection where this Mac set it up (D10: how the app reaches the
/// library, not one of its holdings), and keeps a registration under that
/// name that this Mac did not set up, which is the app's own.
@Suite("Published device status · Agent Tooling's own connection", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct PublishedDeviceStatusOwnConnectionTests {
    @Test func anAppsHoldingsLeaveOutOnlyTheConnectionThisMacSetUp() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterInstall)
        let workspace = sample.workspace
        await workspace.device.adopt(
            workspace.device.observations.map { observation in
                guard observation.surface == .geminiCLI else { return observation }
                var registered = observation
                registered.discoveredMCPServers.append(AgentToolingConnection.declaredName)
                return registered
            })

        let status = try #require(
            PublishedDeviceStatus.current(device: workspace.device, library: workspace.library, deployment: workspace.deployment))
        func held(_ surface: TargetSurface) -> Int? { status.apps.first { $0.surface == surface }?.mcpServerCount }
        func found(_ surface: TargetSurface) -> [String] {
            workspace.device.observations.first { $0.surface == surface }?.discoveredMCPServers ?? []
        }

        for surface in [TargetSurface.codexCLI, .claudeCode] {
            #expect(found(surface).contains(AgentToolingConnection.declaredName), "\(surface)")
            #expect(held(surface) == found(surface).count - 1, "\(surface)")
        }
        #expect(held(.geminiCLI) == found(.geminiCLI).count, "a registration this Mac did not set up is the app's own")
    }
}
