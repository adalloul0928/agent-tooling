import AgentToolingCore
import AppKit
import Foundation

/// Injects setup's filesystem roots, clients, readers, commands, and session factory.
/// Screens use these services rather than constructing their own. Tests provide
/// synthetic homes and scripted services before a workspace exists.
@MainActor
struct LaunchpadEnvironment {
    /// The home folder every read looks in.
    var homeURL: URL
    /// The support folder the library is created in; nil for the default.
    var supportRoot: URL?
    /// This copy of Agent Tooling.
    var bundleURL: URL
    /// The clock the stage stamps what it records with.
    var now: () -> Date
    /// A command runner over the home folder, with the given timeout or the
    /// runner's own.
    var makeRunner: @Sendable (Duration?) -> any CommandRunning
    /// Where `client`'s tool is, looking from the home folder, or nil.
    var locate: @Sendable (ClientKind, URL) -> URL?
    /// Applies tool folders to every lookup in the process.
    var registerToolRoots: @Sendable ([String]) -> Void
    /// How the chosen apps' sign-in is read before the shell exists.
    var signInReader: any SetupSignInReading
    /// The adapters a read uses, finding tools through `locate`.
    var registry: ClientAdapterRegistry
    /// Reads one chosen app before a workspace exists, reporting each place
    /// and command of the manifest as it lands. A test hands in a scripted
    /// reading.
    var firstRead: (ClientKind, FirstReadManifest) -> FirstRead.Reading
    /// The services the workspace's sessions are built with.
    var sessions: WorkspaceLaunch.Services
    /// Where this copy runs from, and whether its helper may be registered.
    var installation: () -> AgentToolingInstallation
    /// This Mac's name as other Macs see it.
    var deviceName: @Sendable () async -> String
    /// This Mac's family ("Mac mini"), or nil.
    var macModelFamily: () -> String?
    /// How the stage moves: the live stage moves fully (Reduce Motion still
    /// applies); a render or a gallery capture draws its final frame.
    var motion: StageMotion

    /// Where a workspace's setup record is kept, from its container: the same
    /// store the sessions are built with, so a record written before the
    /// sessions exist is the one they read.
    var progressStore: @Sendable (URL) -> any SetupProgressStoring { sessions.setupProgressStore }

    /// The stage as the app runs it, pointed where this launch was told to
    /// look.
    static func live(context: LaunchContext) -> LaunchpadEnvironment {
        let home = context.homeRoot ?? FileManager.default.homeDirectoryForCurrentUser
        let locate: @Sendable (ClientKind, URL) -> URL? = { client, homeURL in
            ClientExecutableLocator.locate(client, homeURL: homeURL)
        }
        let registry = ClientAdapterRegistry.bundled(locate: locate)
        let makeRunner: @Sendable (Duration?) -> any CommandRunning = { timeout in
            if let timeout { return ProcessCommandRunner(timeout: timeout, homeURL: home) }
            return ProcessCommandRunner(homeURL: home)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let bundleURL = Bundle.main.bundleURL
        return LaunchpadEnvironment(
            homeURL: home,
            supportRoot: context.workspaceRoot,
            bundleURL: bundleURL,
            now: { .now },
            makeRunner: makeRunner,
            locate: locate,
            registerToolRoots: { ClientExecutableLocator.registerAdditionalRoots($0) },
            signInReader: LiveSetupSignInReader(probe: AccountSurfaceProbe.live(homeURL: home, appVersion: version)),
            registry: registry,
            firstRead: { client, manifest in
                FirstRead.read(client, homeURL: home, manifest: manifest, runner: makeRunner(nil), registry: registry)
            },
            sessions: WorkspaceLaunch.Services(),
            installation: { AgentToolingInstallation.inspect(bundleURL: bundleURL, homeURL: home) },
            deviceName: {
                await Task.detached { Host.current().localizedName ?? "This Mac" }.value
            },
            macModelFamily: { MacModel.family() },
            motion: .full)
    }
}
