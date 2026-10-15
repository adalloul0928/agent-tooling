import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// After an apply, the applied provider has to show the file the apply just
/// wrote, even when an unrelated read of that provider is already in flight.
/// The post-apply refresh used to go through the coalescing read, which drops
/// a provider already being read, so the rows kept their pre-apply state until
/// the background read happened to finish.
@Suite("Accounts · the applied provider refreshes")
@MainActor
struct WorkspaceAccountsSessionApplyRefreshTests {
    /// Reads Claude from a settings file like the real reader, and snapshots
    /// the file the instant it is asked, so a read held open carries the state
    /// the file had when the read began — not when it was released. A
    /// `.contents` read blocks on the gate once closed.
    final class GatedSettingsReader: AccountSurfaceReading, @unchecked Sendable {
        let home: URL
        private let lock = NSLock()
        private var isOpen = true
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private let startedContinuation: AsyncStream<Void>.Continuation
        let started: AsyncStream<Void>

        init(home: URL) {
            self.home = home
            (started, startedContinuation) = AsyncStream.makeStream()
        }

        func close() { lock.withLock { isOpen = false } }

        func open() {
            let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for continuation in released { continuation.resume() }
        }

        func read(_ providers: [AccountProvider], depth: AccountSurfaceProbe.Depth, now: Date) async -> [AccountObservation] {
            // Snapshot the file before any gate, so a held read reflects the
            // state at the moment it started, not when it is released.
            let snapshots = providers.map { provider -> AccountObservation in
                guard provider == .claude else {
                    return AccountObservation(provider: provider, observedAt: now, unavailableReason: "Not read in tests.")
                }
                let text = (try? String(contentsOf: home.appending(path: ".claude/settings.json"), encoding: .utf8)) ?? ""
                let file = ClaudeAccountParsing.settings(fromJSON: text).switches
                return AccountObservation(
                    provider: .claude, observedAt: now, signIn: .init(method: .subscription, email: "me@example.com"),
                    switches: file, fileValues: file, contentsRead: depth == .contents)
            }
            if depth == .contents {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock { () -> Bool in
                        if isOpen { return true }
                        waiting.append(continuation)
                        return false
                    }
                    if resumeNow {
                        continuation.resume()
                    } else {
                        // Only a read that is actually held signals that it has
                        // started, so the test waits for the gated read rather
                        // than an earlier ungated one.
                        startedContinuation.yield()
                    }
                }
            }
            return snapshots
        }
    }

    @Test func applyRefreshesTheProviderEvenWithABackgroundReadInFlight() async throws {
        // The fixture needs a reader at init; the real session is built below
        // against the fixture's own home so the reader and the apply agree on
        // one settings file.
        let fixture = try await ShellRenderFixture(
            deviceObserver: StubDeviceObserver(observations: [
                ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "2.1.300"),
            ]),
            accountReader: StubAccountReader())
        defer { fixture.remove() }

        let reader = GatedSettingsReader(home: fixture.home)
        let session = WorkspaceAccountsSession(
            library: fixture.workspace.library, device: fixture.workspace.device, service: fixture.workspace.service,
            store: fixture.store, sync: nil, homeRoot: fixture.home, reader: reader)

        // A starting settings file so the applied edit has somewhere to land.
        let settings = fixture.home.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)

        await session.read()
        #expect(await session.setChoice(.init(.skillSync), to: .off))
        #expect(session.plan(.claude)?.changes.map(\.key) == [.init(.skillSync)])

        // A background read of Claude, held before it can finish.
        reader.close()
        let background = Task { await session.read([.claude], depth: .contents) }
        for await _ in reader.started { break }

        // Apply while that read is in flight, then let the read go. The sleep
        // gives apply time to write the file and reach its post-apply refresh:
        // with the bug that refresh is coalesced away and apply finishes here;
        // with the fix apply is now waiting on the in-flight read.
        let applied = Task { await session.apply(.claude) }
        try await Task.sleep(for: .milliseconds(200))
        reader.open()
        _ = await applied.value
        await background.value

        #expect(session.observation(.claude)?.effectiveValue(of: .init(.skillSync)) == .off,
                "the applied file is read back even though a read was in flight")
        #expect(session.plan(.claude)?.isEmpty == true, "and the plan follows what was applied")
        let written = try #require(try? String(contentsOf: settings, encoding: .utf8))
        #expect(written.contains("syncClaudeAiSkills"))
    }
}
