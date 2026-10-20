import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import SwiftUI

@testable import AgentToolingApp

/// Isolated setup fixture with synthetic client homes, scratch storage and scripted
/// services. Tool discovery stays inside the fixture; commands, first reads and
/// sign-in responses never use host apps or network. Persists real setup records
/// beside the scratch library and exposes stage snapshots for rendering tests.
@MainActor
struct LaunchpadFixture {
    /// The sample-world home, with each found app's tool planted in it.
    let world: ClientHomeFixture
    /// The support folder the library is created in.
    let support: URL
    /// What a real first read of each found app produces here, by app, read
    /// once through the bundled adapters and the sample world's scripted
    /// commands, and dated at the sample world's clock.
    let observations: [ClientKind: TargetObservation]
    let firstReads: ScriptedFirstRead
    let signIn: StubSignInReader
    let observer: CountingDeviceObserver
    let setup: StubSetupServices
    let insights: StubInsightsServices
    let accountReader: StubAccountReader
    /// The stage's environment over all of the above. A test may change it
    /// before taking a flow.
    var environment: LaunchpadEnvironment

    /// `installation` is where this copy says it runs from; by default a
    /// development build, which is offered no move, so a first run opens on
    /// Welcome. `readGate` holds every app's first read before it finishes,
    /// and `signInGate` every sign-in read, until the test releases them.
    init(
        _ which: ClientHomeFixture.World = .juniper,
        motion: StageMotion = .still,
        installation: AgentToolingInstallation? = nil,
        readGate: GatedCommandRunner? = nil,
        signInGate: GatedCommandRunner? = nil
    ) async throws {
        let world = try ClientHomeFixture(which)
        do {
            if which == .juniper {
                // The audit checks reachability without running this fixture command.
                try world.home.plant(".local/bin/npx", "#!/bin/sh\nexit 1\n")
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: world.home.appending(".local/bin/npx").path(percentEncoded: false))
            }
            let support = world.home.root.appending(path: "support", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var observations: [ClientKind: TargetObservation] = [:]
            for var observation in await world.registry.scanAll(
                homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)
            {
                observation.lastScannedAt = ClientHomeFixture.now
                if let client = observation.surface.client { observations[client] = observation }
            }
            self.world = world
            self.support = support
            self.observations = observations
            firstReads = ScriptedFirstRead(observations: observations, gate: readGate)
            signIn = StubSignInReader(answers: Self.signIns(for: which), gate: signInGate)
            observer = CountingDeviceObserver(Array(observations.values))
            setup = StubSetupServices()
            insights = StubInsightsServices(answer: ShellRenderFixture.insightsReport(generatedAt: ClientHomeFixture.now))
            accountReader = StubAccountReader(answers: Self.signIns(for: which))
            environment = Self.environment(
                world: world, support: support, motion: motion, firstReads: firstReads, signIn: signIn,
                observer: observer, setup: setup, insights: insights, accountReader: accountReader,
                installation: installation)
        } catch {
            world.remove()
            throw error
        }
    }

    /// The home folder.
    var home: URL { world.url }

    /// What Your apps decides on this Mac when nothing is changed: every found
    /// app, the projects choice on.
    var seed: LaunchpadSeed { LaunchpadSeed(chosen: world.found) }

    /// The found apps' observations, in the app order.
    var orderedObservations: [TargetObservation] {
        ClientKind.allCases.compactMap { observations[$0] }
    }

    /// A stage at `entry`, over `workspace` when the entry needs one.
    func flow(_ entry: SetupEntry = .firstRun, workspace: WorkspaceLaunch.Workspace? = nil) -> LaunchpadFlow {
        LaunchpadFlow(entry: entry, environment: environment, workspace: workspace)
    }

    /// The stage as a render test or the gallery draws it: still, at the
    /// sample world's clock.
    func stage(_ flow: LaunchpadFlow) -> some View {
        LaunchpadStageView(flow: flow)
            .environment(\.snapshotNow, ClientHomeFixture.now)
    }

    /// The setup record on disk for `workspace`, read the way the next launch
    /// reads it.
    func savedRecord(for workspace: WorkspaceLaunch.Workspace) -> SetupProgressRecord? {
        LiveSetupProgressStore(container: workspace.store.databaseURL.deletingLastPathComponent()).load()
    }

    /// Whether the support folder holds a library record, readable or not.
    var hasWorkspace: Bool { WorkspaceLaunch.recordState(supportRoot: support) != .none }

    func remove() { world.remove() }

    // MARK: The scripted environment

    private static func environment(
        world: ClientHomeFixture, support: URL, motion: StageMotion, firstReads: ScriptedFirstRead,
        signIn: StubSignInReader, observer: CountingDeviceObserver, setup: StubSetupServices,
        insights: StubInsightsServices, accountReader: StubAccountReader, installation: AgentToolingInstallation?
    ) -> LaunchpadEnvironment {
        let bundle = support.appending(path: "Agent Tooling.app", directoryHint: .isDirectory)
        let device = world.world == .cedar ? "Cedar" : "Juniper"
        let family = world.world == .cedar ? "Mac mini" : "MacBook Pro"
        return LaunchpadEnvironment(
            homeURL: world.url,
            supportRoot: support,
            bundleURL: bundle,
            now: { ClientHomeFixture.now },
            makeRunner: { _ in world.scriptedRunner() },
            locate: { client, _ in world.locate(client) },
            registerToolRoots: { _ in },
            signInReader: signIn,
            registry: world.registry,
            firstRead: { client, manifest in firstReads.reading(client, manifest: manifest) },
            sessions: WorkspaceLaunch.Services(
                deviceObserver: observer,
                marketplaceProviders: { _ in [StubMarketplaceProvider(packages: LaunchpadFixture.catalogListings)] },
                insightsServices: { _ in insights },
                requestQueue: StubPendingRequestQueue(),
                setupServices: { _ in setup },
                accountReader: { _ in accountReader },
                setupProgressStore: { LiveSetupProgressStore(container: $0) },
                registerToolRoots: { _ in }),
            installation: {
                installation
                    ?? AgentToolingInstallation(
                        bundleURL: bundle, location: .developmentBuild, mcpHelperURL: nil, cliHelperURL: nil,
                        isAdHocSigned: true)
            },
            deviceName: { device },
            macModelFamily: { family },
            motion: motion)
    }

    /// How the sample world's apps sign in: Codex with ChatGPT Plus, Claude
    /// Code with claude.ai Max.
    nonisolated static func signIns(for world: ClientHomeFixture.World) -> [AccountProvider: AccountObservation] {
        guard world != .emptyMac else { return [:] }
        return [
            .chatGPT: AccountObservation(
                provider: .chatGPT, observedAt: ClientHomeFixture.now, clientVersion: "0.164.0",
                signIn: AccountSignIn(method: .subscription, email: "you@example.com", plan: "plus")),
            .claude: AccountObservation(
                provider: .claude, observedAt: ClientHomeFixture.now, clientVersion: "2.1.304",
                signIn: AccountSignIn(method: .subscription, email: "you@example.com", plan: "max")),
        ]
    }
}

// MARK: - Scripted services

/// A setup record kept in memory: the render fixture's default, so every
/// existing screen test is a workspace made before Launchpad.
final class StubSetupProgressStore: SetupProgressStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: SetupProgressRecord?
    private var saves = 0
    private var failing = false

    init(_ record: SetupProgressRecord? = nil) {
        self.record = record
    }

    /// The record as last saved.
    var saved: SetupProgressRecord? { lock.withLock { record } }
    var saveCount: Int { lock.withLock { saves } }
    /// When true, every save throws: a store that will not take a write.
    var failsSaves: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func load() -> SetupProgressRecord? { lock.withLock { record } }

    func save(_ record: SetupProgressRecord) throws {
        try lock.withLock {
            if failing { throw CocoaError(.fileWriteNoPermission) }
            self.record = record
            saves += 1
        }
    }
}

/// Sign-in reads answered from memory. It counts the login-shell probes and
/// records each provider read, and a gate holds every read until released.
final class StubSignInReader: SetupSignInReading, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [AccountProvider: AccountObservation]
    private let gate: GatedCommandRunner?
    private var probes = 0
    private var asked: [AccountProvider] = []

    init(answers: [AccountProvider: AccountObservation] = [:], gate: GatedCommandRunner? = nil) {
        self.answers = answers
        self.gate = gate
    }

    /// How many times the login shell was asked.
    var shellProbes: Int { lock.withLock { probes } }
    /// Each provider read, in the order asked.
    var reads: [AccountProvider] { lock.withLock { asked } }

    func readShellOverrides() async -> [AccountShellOverride]? {
        lock.withLock { probes += 1 }
        return []
    }

    func read(_ provider: AccountProvider, shellOverrides: [AccountShellOverride]?, now: Date) async -> AccountObservation {
        lock.withLock { asked.append(provider) }
        if let gate {
            _ = try? await gate.run(executable: "sign-in", arguments: [provider.rawValue], currentDirectory: nil)
        }
        return answers[provider] ?? AccountObservation(provider: provider, observedAt: now, unavailableReason: "Not read in tests.")
    }
}

/// Each app's first read from a script: the app's places and commands from
/// the manifest as events, in order, then the observation a real read of the
/// sample world produced. A gate holds each read before it finishes; stopping
/// a reading ends it with nothing more, as the real one does.
final class ScriptedFirstRead: @unchecked Sendable {
    private let lock = NSLock()
    let observations: [ClientKind: TargetObservation]
    private let gate: GatedCommandRunner?
    private var begun: [ClientKind] = []

    init(observations: [ClientKind: TargetObservation], gate: GatedCommandRunner? = nil) {
        self.observations = observations
        self.gate = gate
    }

    /// The apps whose read began, in order.
    var started: [ClientKind] { lock.withLock { begun } }

    func reading(_ client: ClientKind, manifest: FirstReadManifest) -> FirstRead.Reading {
        lock.withLock { begun.append(client) }
        let (events, continuation) = AsyncStream.makeStream(of: FirstRead.Event.self)
        let observation = observations[client]
        let gate = self.gate
        let app = manifest.apps.first { $0.client == client }
        let task = Task {
            for place in app?.places ?? [] { continuation.yield(.placeRead(client, place.id)) }
            for command in app?.commands ?? [] {
                continuation.yield(.commandStarted(client, command.id))
                continuation.yield(.commandFinished(client, command.id, .answered(status: 0, firstLine: nil)))
            }
            if let gate {
                do {
                    _ = try await gate.run(executable: "first-read", arguments: [client.rawValue], currentDirectory: nil)
                } catch {
                    continuation.finish()
                    return
                }
            }
            if !Task.isCancelled, let observation { continuation.yield(.finished(observation)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return FirstRead.Reading(events) {
            task.cancel()
            continuation.finish()
            await task.value
        }
    }
}

/// A device check from a script that counts what it was asked, so a test can
/// prove the stage scanned nothing again, or only the apps an install touched.
final class CountingDeviceObserver: DeviceObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: [TargetObservation]
    private var full = 0
    private var scoped: [Set<ClientKind>] = []

    init(_ observations: [TargetObservation]) {
        answer = observations
    }

    /// What every later check answers.
    func answer(with observations: [TargetObservation]) {
        lock.withLock { answer = observations }
    }

    /// Full checks so far.
    var fullChecks: Int { lock.withLock { full } }
    /// The apps each scoped check asked for, in order.
    var scopedChecks: [Set<ClientKind>] { lock.withLock { scoped } }

    func observe(homeRoot: URL) async throws -> [TargetObservation] {
        lock.withLock {
            full += 1
            return answer
        }
    }

    func observe(homeRoot: URL, clients: Set<ClientKind>) async throws -> [TargetObservation] {
        lock.withLock {
            scoped.append(clients)
            return answer.filter { $0.surface.client.map(clients.contains) ?? false }
        }
    }
}
