import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// An app with no observation on this Mac has not been checked here yet — an
/// app skipped during the first read, say. That is a state to report, not a
/// broken read: the selector is skipped as not checked, and every app that
/// was checked still resolves.
@Suite("Capture · not checked")
struct CaptureNotCheckedTests {
    @Test func aSelectorWithNoObservationIsSkippedNotThrown() async throws {
        let home = try FixtureHome("capture-not-checked")
        defer { home.remove() }

        let result = try await WorkspaceSkillTargetCapture.capture(
            homeURL: home.url, deviceID: WorkspaceObjectID(),
            selectors: [.init(surface: .codexCLI, scope: .user)], observations: [])

        #expect(result.targets.isEmpty)
        #expect(result.skipped.map(\.reason) == [.notChecked(.codexCLI)])
        #expect(result.skipped.map(\.selector) == [.init(surface: .codexCLI, scope: .user)])
    }

    @Test func theAppsThatWereCheckedStillResolve() async throws {
        let home = try FixtureHome("capture-not-checked-mixed")
        defer { home.remove() }
        let checked = try Self.observation(.claudeCode)

        let result = try await WorkspaceSkillTargetCapture.capture(
            homeURL: home.url, deviceID: WorkspaceObjectID(),
            selectors: [.init(surface: .claudeCode, scope: .user), .init(surface: .geminiCLI, scope: .user)],
            observations: [checked])

        #expect(result.targets.map(\.target.selector.surface) == [.claudeCode])
        #expect(result.targets.first?.target.installedClientVersion == checked.version)
        #expect(result.skipped.map(\.reason) == [.notChecked(.geminiCLI)])
    }

    /// Two records of one app are still a broken read, and still thrown.
    @Test func twoObservationsOfOneAppStillThrow() async throws {
        let home = try FixtureHome("capture-not-checked-ambiguous")
        defer { home.remove() }
        let observation = try Self.observation(.codexCLI)

        await #expect(throws: WorkspaceSkillTargetCaptureError.ambiguousObservation(.codexCLI)) {
            _ = try await WorkspaceSkillTargetCapture.capture(
                homeURL: home.url, deviceID: WorkspaceObjectID(),
                selectors: [.init(surface: .codexCLI, scope: .user)], observations: [observation, observation])
        }
    }

    /// A project selector for an app not checked yet is reported as the app
    /// not being checked, the same as its user selector.
    @Test func aProjectSelectorForAnAppNotCheckedIsSkippedToo() async throws {
        let home = try FixtureHome("capture-not-checked-project")
        defer { home.remove() }
        let project = home.appending("code/storefront", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectID = ArtifactID()

        let result = try await WorkspaceSkillTargetCapture.capture(
            homeURL: home.url, deviceID: WorkspaceObjectID(),
            selectors: [.init(surface: .codexCLI, scope: .project, logicalProjectID: projectID)],
            projectRoots: [.init(projectID: projectID, rootPath: project.path(percentEncoded: false))], observations: [])

        #expect(result.targets.isEmpty)
        #expect(result.skipped.map(\.reason) == [.notChecked(.codexCLI)])
    }

    private static func observation(_ surface: TargetSurface) throws -> TargetObservation {
        let client = try #require(surface.client)
        let capabilities = try #require(ClientAdapterRegistry().adapter(for: client)?.capabilities)
        return TargetObservation(surface: surface, installed: true, version: "1.0", capabilities: capabilities)
    }
}
