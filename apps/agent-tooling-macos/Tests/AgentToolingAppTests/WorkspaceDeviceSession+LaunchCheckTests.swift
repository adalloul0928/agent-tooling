import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// What counts as this launch's check of the apps, which the shell's launch
/// work asks before it checks them: a check of every app, or the stage's
/// read, but never the re-check of only the apps an install touched (D29),
/// so a shell that opens after a stage install still checks every app.
@Suite("Device session · this launch's check", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceDeviceSessionLaunchCheckTests {
    @Test func aReCheckOfTheAppsAnInstallTouchedIsNotThisLaunchsCheck() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let observer = CountingDeviceObserver([
            ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.304")
        ])
        let device = WorkspaceDeviceSession(
            service: fixture.workspace.service, library: fixture.workspace.library, store: fixture.store,
            homeRoot: fixture.home, observer: observer, registerToolRoots: { _ in })

        // Recorded and shown like any check, but only Claude Code was read.
        await device.refresh(only: [.claude])
        #expect(observer.scopedChecks == [[.claude]])
        #expect(device.observations.contains { $0.surface == .claudeCode && $0.installed })
        #expect(device.lastCheckedAt != nil)
        #expect(!device.hasCheckedThisLaunch)

        await device.refresh()
        #expect(observer.fullChecks == 1)
        #expect(device.hasCheckedThisLaunch)
    }
}
