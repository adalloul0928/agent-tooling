import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shared apparatus behind every section render test.
///
/// The sessions behind these screens are covered elsewhere; what is not covered
/// by any of that is a screen failing to build, or laying out to nothing. Both
/// are invisible until someone opens the app, which is exactly when it is most
/// expensive to find out.
///
/// A section's own test adds what its screen needs to `ShellRenderFixture` from
/// its own `Fixture+<Section>.swift`, so this file stays the one thing every
/// screen shares and nothing has to be edited twice.

/// A real window's worth of space, so a screen that only lays out at some
/// convenient size fails here rather than on a Mac.
let shellWindowSize = CGSize(width: 1_100, height: 760)

/// The shell, opened on one section, at the size a window would give it.
@MainActor
func renderShell(_ section: AppSection, fixture: ShellRenderFixture) -> some View {
    AppShellView(workspace: fixture.workspace, initialSection: section)
        .frame(width: shellWindowSize.width, height: shellWindowSize.height)
}

/// Lays the screen out at a real window size and rasterizes it.
///
/// A screen that throws never gets here. A screen that builds but puts nothing
/// on the canvas rasterizes to a single flat colour, which is the blank frame a
/// person would report as "it opened to nothing".
@MainActor
func expectDrawn(
    _ view: some View,
    _ location: SourceLocation = #_sourceLocation
) throws {
    let bitmap = try rasterize(view, location)
    #expect(
        distinctColours(in: bitmap) > 4, "the screen drew a blank frame",
        sourceLocation: location)
}

@MainActor
func rasterize(
    _ view: some View,
    _ location: SourceLocation = #_sourceLocation
) throws -> NSBitmapImageRep {
    let size = shellWindowSize
    let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
    host.frame = CGRect(origin: .zero, size: size)
    // A bare hosting view never finishes compositing an enabled glass control
    // before a synchronous read-back, and the whole frame comes back flat. A
    // real, borderless window given one run-loop turn settles it.
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.width > 0, "the screen laid out to no width", sourceLocation: location)
    #expect(host.fittingSize.height > 0, "the screen laid out to no height", sourceLocation: location)

    let bitmap = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds),
        "the screen produced no drawable area", sourceLocation: location)
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.orderOut(nil)
    return bitmap
}

/// Samples on a coarse grid; enough to tell text and controls from an empty
/// wash without depending on exact pixels or on the render being byte-identical
/// across macOS versions.
func distinctColours(in bitmap: NSBitmapImageRep) -> Int {
    var seen = Set<UInt32>()
    let step = 7
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
            guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
            let packed =
                UInt32(colour.redComponent * 255) << 16
                | UInt32(colour.greenComponent * 255) << 8
                | UInt32(colour.blueComponent * 255)
            seen.insert(packed)
            if seen.count > 4 { return seen.count }
        }
    }
    return seen.count
}

/// This Mac's apps, scripted.
///
/// A render test that ran a real client would take a verdict from whatever
/// happens to be installed on the machine running it, and would put a different
/// sidebar on screen depending on whose Mac it was.
struct StubDeviceObserver: DeviceObserving {
    var observations: [TargetObservation] = [
        ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true),
        ShellRenderFixture.observation(.codexCLI, installed: false, commandAvailable: false),
    ]

    func observe(homeRoot: URL) async throws -> [TargetObservation] { observations }
}

/// A workspace with the shapes each screen reaches for: a plugin that carries a
/// skill, a standalone skill, a server, a preset and a project.
///
/// The store is real and lives in a temporary folder, and the sessions come from
/// the app's own launch wiring, so a screen that outgrows what launch hands it
/// fails here rather than only on a real Mac.
///
/// Every service that reaches outside the app is scripted here rather than in a
/// test's own environment, because launch is where the app itself settles them:
/// the catalog answers from memory, the scan is a canned report and the review
/// queue is a list. A test that wants different answers hands them to this
/// initializer, and no screen can reach past what it was given.
@MainActor struct ShellRenderFixture {
    static let plugin = ArtifactID()
    static let child = ArtifactID()
    static let skill = ArtifactID()
    static let server = ArtifactID()
    static let presetID = ArtifactID()
    static let projectID = ArtifactID()
    let root: URL
    let home: URL
    let store: WorkspaceRevisionStore
    let workspace: WorkspaceLaunch.Workspace

    init(
        deviceObserver: any DeviceObserving = StubDeviceObserver(),
        marketplaceProviders: [any MarketplaceProvider] = [StubMarketplaceProvider()],
        insightsServices: any InsightsServicing = StubInsightsServices(
            answer: ShellRenderFixture.insightsReport()),
        requestQueue: any PendingRequestQueuing = StubPendingRequestQueue(),
        readsLibrary: Bool = true
    ) async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "shell-render-\(UUID())", directoryHint: .isDirectory)
        let container = root.appending(path: "store", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        for directory in [container, home] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let writerID = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [
                    .init(
                        identity: .init(id: Self.plugin, kind: .nativePlugin, displayName: "Example Plugin"),
                        authority: .nativeOwned,
                        declaredName: "example-plugin",
                        nativeRoutes: [.init(client: .claude, externalPluginID: "example@vendor")]),
                    // A native-owned skill member has a file of its own, so the
                    // document requires it to say where inside the package. It
                    // carries no route: the package it belongs to holds that.
                    .init(
                        identity: .init(
                            id: Self.child, kind: .skill, displayName: "Bundled Skill",
                            parentPackageID: Self.plugin),
                        authority: .nativeOwned,
                        declaredName: "bundled-skill",
                        packageRelativePath: "skills/bundled"),
                    .init(
                        identity: .init(id: Self.skill, kind: .skill, displayName: "Standalone Skill"),
                        authority: .centralPersonal, declaredName: "standalone-skill"),
                    .init(
                        identity: .init(id: Self.server, kind: .mcpServer, displayName: "Example Server"),
                        authority: .trackedOnly, declaredName: "example-server"),
                    .init(
                        identity: .init(id: Self.presetID, kind: .preset, displayName: "Starter"),
                        authority: .centralPersonal),
                    .init(
                        identity: .init(id: Self.projectID, kind: .logicalProject, displayName: "Project A"),
                        authority: .centralPersonal),
                ],
                logicalProjects: [
                    .init(
                        id: Self.projectID, name: "Project A",
                        repositoryHints: ["https://github.com/acme/project"])
                ],
                presets: [
                    .init(id: Self.presetID, name: "Starter", revision: 1, memberArtifactIDs: [Self.skill])
                ]))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        store = try WorkspaceRevisionStore(
            containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        // The app's own wiring, so a screen that outgrows what launch hands it
        // fails here rather than only on a real Mac.
        workspace = WorkspaceLaunch.sessions(
            store: store, homeRoot: home, isFirstRun: true, deviceObserver: deviceObserver,
            marketplaceProviders: { _ in marketplaceProviders },
            insightsServices: { _ in insightsServices }, requestQueue: requestQueue)
        // A test of the cold launch itself wants the library still unread.
        if readsLibrary { await workspace.library.refresh() }
    }

    /// One scripted client answer, in the shape a scan reports. Built off the
    /// main actor so a stub observer can script one before there is a fixture.
    nonisolated static func observation(
        _ surface: TargetSurface, installed: Bool, commandAvailable: Bool,
        version: String? = nil, scannedAt: Date = .now
    ) -> TargetObservation {
        .init(
            surface: surface, installed: installed, commandAvailable: commandAvailable,
            version: version,
            capabilities: .init(
                supportsPluginInstall: false, supportsProjectScope: false,
                supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                supportsConnectorDiscovery: false, requiresNewSession: false,
                requiresRestart: false, supportsMachineReadableOutput: false),
            lastScannedAt: scannedAt)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
