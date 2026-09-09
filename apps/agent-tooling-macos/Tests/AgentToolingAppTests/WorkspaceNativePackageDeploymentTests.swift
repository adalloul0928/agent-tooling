import Darwin
import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// A native package reaches the Install surface when this build has a recorded
/// command for that client, and is excluded by name when it does not.
@MainActor
struct WorkspaceNativePackageDeploymentTests {
    @Test func aRecordedCommandMakesThePackageOfferable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()

        await session.prepare()

        let plan = try #require(session.plan)
        #expect(plan.exclusions.filter { $0.reason == .missingNativeRoute }.isEmpty,
                "\(plan.exclusions)")
        guard case .installNativePackage(let route) = try #require(plan.items.first).action else {
            Issue.record("Expected a native package install, got \(String(describing: plan.items.first?.action))")
            return
        }
        #expect(route == .init(client: .codex, externalPluginID: "browser"))
    }

    @Test func aClientWithNoRecordedCommandIsExcludedByNameNotAttempted() async throws {
        let fixture = try await Fixture(client: .gemini)
        defer { fixture.remove() }
        let session = await fixture.session()

        await session.prepare()

        // Nothing here has read Gemini's install command, and a plausible one
        // would be the invention the register exists to avoid.
        #expect(session.plan?.items.isEmpty == true)
        #expect(session.plan?.exclusions.map(\.reason) == [.missingNativeRoute])
    }

    @Test func theBridgeProducesItsOwnApprovedCommandOperation() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.prepare()
        let plan = try #require(session.plan)

        let plans = WorkspaceDeploymentSession.commandPlans(
            plan: plan, snapshot: try #require(fixture.library.state?.snapshot),
            homeRoot: fixture.home)

        let built = try #require(plans.plugins.first)
        #expect(built.externalPluginID == "browser")
        #expect(built.executableURL.path == fixture.codexPath)
        #expect(built.arguments == ["plugin", "add", "browser"])
        // One approval per app, and it says what it is about to run.
        let operation = try #require(
            WorkspaceDeploymentOperations.operations(nativePlugins: plans.plugins).first)
        #expect(operation.kind == .installPlugin)
        #expect(operation.requiresConfirmation)
        #expect(operation.steps.first?.kind == .command)
        #expect(operation.steps.first?.arguments == ["plugin", "add", "browser"])
    }

    @Test func withoutTheClientsOwnToolOnThisMacNoCommandIsOffered() async throws {
        let fixture = try await Fixture(installClientTool: false)
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.prepare()

        let plans = WorkspaceDeploymentSession.commandPlans(
            plan: try #require(session.plan),
            snapshot: try #require(fixture.library.state?.snapshot), homeRoot: fixture.home)

        // A command naming a tool that is not there could be approved and could
        // never run.
        #expect(plans.plugins.isEmpty)
    }

    @MainActor private struct Fixture {
        static let pluginID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        let root: URL
        let home: URL
        let store: WorkspaceRevisionStore
        let library: WorkspaceLibrarySession
        let service: WorkspaceApplicationService
        var codexPath: String { home.appending(path: ".local/bin/codex").standardizedFileURL.path }

        init(client: ClientKind = .codex, installClientTool: Bool = true) async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "native-package-\(UUID())")
            home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if installClientTool {
                let bin = home.appending(path: ".local/bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                for name in ["codex", "gemini"] {
                    let tool = bin.appending(path: name)
                    try Data("#!/bin/sh\n".utf8).write(to: tool)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                          ofItemAtPath: tool.path)
                }
            }

            let surface: TargetSurface = client == .codex ? .codexCLI : .geminiCLI
            let writerID = WorkspaceObjectID()
            let route = NativePackageRoute(client: client, externalPluginID: "browser")
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [.init(
                    identity: .init(id: Self.pluginID, kind: .nativePlugin, displayName: "Browser"),
                    authority: .nativeOwned, declaredName: "browser", nativeRoutes: [route])],
                assignments: [.init(artifactID: Self.pluginID,
                                    destination: .init(surface: surface, scope: .user),
                                    reason: .manual)]))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            device.capabilityEvidence = [
                .init(surface: surface, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                      component: .plugin, scopes: [.user], support: .supported,
                      observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ]
            device.observations = [
                .init(surface: surface, installed: true, commandAvailable: true, version: "1.0.0",
                      capabilities: .init(supportsPluginInstall: true, supportsProjectScope: true,
                                          supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                                          supportsConnectorDiscovery: false, requiresNewSession: true,
                                          requiresRestart: false, supportsMachineReadableOutput: true),
                      lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ]
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(service: service, workspaceID: document.workspaceID,
                                              deviceID: device.deviceID, access: .writable)
        }

        func session() async -> WorkspaceDeploymentSession {
            await library.refresh()
            return WorkspaceDeploymentSession(service: service, library: library, store: store,
                                              homeRoot: home, contentStore: nil)
        }

        func remove() {
            func unlock(_ url: URL) {
                var value = stat()
                guard lstat(url.path, &value) == 0 else { return }
                _ = chmod(url.path, 0o700)
                guard value.st_mode & S_IFMT == S_IFDIR else { return }
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                    unlock(child)
                }
            }
            unlock(root)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
