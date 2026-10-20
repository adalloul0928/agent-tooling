import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// Seeds a scratch library for the running-Mac checklist (plan §10, item 2):
/// a packaged app launched with `--workspace <folder>/ws --home <folder>/home`
/// then opens on its main window, as a Mac that already has a library does.
/// The library is made through the same API CI's smoke step seeds with, and
/// reads no app: its registry has no adapters.
///
/// Enabled only when `AGENT_TOOLING_QA_SEED` names a folder, so a normal
/// `swift test` never writes one.
@Suite("Running-Mac seed", .serialized, .enabled(if: RunningMacSeed.folder != nil))
struct RunningMacSeedTests {
    @Test func seedsALibraryForALaunch() async throws {
        let folder = try #require(RunningMacSeed.folder)
        let support = folder.appending(path: "ws", directoryHint: .isDirectory)
        let home = folder.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        _ = try await WorkspaceLocator(root: support).openOrCreate(
            homeURL: home, runner: ProcessCommandRunner(homeURL: home), registry: ClientAdapterRegistry(adapters: []))
        guard case .present = WorkspaceLaunch.recordState(supportRoot: support) else {
            Issue.record("the seeded library has no record a launch reads")
            return
        }
    }
}

/// Where the running-Mac seed writes, or nil when it is switched off.
enum RunningMacSeed {
    static let folder: URL? = {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TOOLING_QA_SEED"], !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }()
}
