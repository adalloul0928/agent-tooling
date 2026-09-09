import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceSkillTargetCaptureTests {
    @Test func userAndProjectRoutesMatchWorkspaceLibraryPlansForAllClients() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let deviceID = Self.object("00000000-0000-0000-0000-000000000001")
        let projectID = Self.artifactID("00000000-0000-0000-0000-000000000002")
        let userSkill = try fixture.skill(name: "user-route", scope: .user)
        let projectSkill = try fixture.skill(name: "project-route", scope: .project)
        let clients = Set(ClientKind.allCases)

        let userPlan = try fixture.library.installPlan(for: userSkill, targets: clients, homeURL: fixture.home)
        let userCapture = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home, deviceID: deviceID,
            selectors: Self.selectors(scope: .user), observations: Self.observations())
        #expect(Set(userCapture.map(\.plannedDirectory.path)) == Set(userPlan.steps.compactMap {
            $0.destinationPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        }))
        #expect(Set(userCapture.map(\.plannedDirectory.path)) == Set([
            fixture.home.appending(path: ".claude/skills").path,
            fixture.home.appending(path: ".agents/skills").path,
            fixture.home.appending(path: ".gemini/skills").path,
        ]))

        let projectPlan = try fixture.library.installPlan(for: projectSkill, targets: clients, homeURL: fixture.home)
        let projectCapture = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home, deviceID: deviceID,
            selectors: Self.selectors(scope: .project, projectID: projectID),
            projectRoots: [.init(projectID: projectID, rootPath: fixture.project.path)],
            observations: Self.observations())
        #expect(Set(projectCapture.map(\.plannedDirectory.path)) == Set(projectPlan.steps.compactMap {
            $0.destinationPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        }))
        #expect(Set(projectCapture.map(\.plannedDirectory.path)) == Set([
            fixture.project.appending(path: ".claude/skills").path,
            fixture.project.appending(path: ".agents/skills").path,
            fixture.project.appending(path: ".gemini/skills").path,
        ]))
    }

    @Test func aliasedClientDirectoriesSharePhysicalIdentityAndResolverCoalesces() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = fixture.container.appending(path: "shared-skills")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        for parent in [".claude", ".agents"] {
            let root = fixture.home.appending(path: parent)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: root.appending(path: "skills"), withDestinationURL: shared)
        }
        let deviceID = Self.object("00000000-0000-0000-0000-000000000010")
        let captured = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home, deviceID: deviceID,
            selectors: [.init(surface: .claudeCode, scope: .user), .init(surface: .codexCLI, scope: .user)],
            observations: Self.observations(surfaces: [.claudeCode, .codexCLI]))
        let canonicalShared = try Self.canonicalExistingDirectory(shared).path
        #expect(captured.map(\.canonicalDirectory.path) == [canonicalShared, canonicalShared])
        #expect(Set(captured.map(\.target.physicalDestinationID)).count == 1)

        let skillID = Self.artifactID("00000000-0000-0000-0000-000000000011")
        let digest = ContentDigest(value: String(repeating: "a", count: 64))
        let contributions = captured.enumerated().map { index, item in
            AssignmentContribution(
                id: Self.object(index == 0
                    ? "00000000-0000-0000-0000-000000000012"
                    : "00000000-0000-0000-0000-000000000013"),
                artifactID: skillID,
                destination: .init(surface: item.target.selector.surface, scope: .user),
                reason: .manual)
        }
        let resolution = WorkspaceAssignmentResolver.resolve(
            artifacts: [.init(
                identity: .init(id: skillID, kind: .skill, displayName: "Skill"),
                authority: .centralPersonal, contentDigest: digest)],
            contributions: contributions, currentDeviceID: deviceID,
            targets: captured.map(\.target),
            capabilityEvidence: Self.capabilities(surfaces: [.claudeCode, .codexCLI]),
            contentEvidence: [.init(artifactID: skillID, digest: digest)])
        #expect(resolution.issues.isEmpty)
        #expect(resolution.requirements.count == 1)
        #expect(resolution.requirements.first?.contributions.count == 2)
    }

    @Test func physicalIdentityIncludesDeviceID() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selector = [ResolvedAssignmentSelector(surface: .codexCLI, scope: .user)]
        let first = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home,
            deviceID: Self.object("00000000-0000-0000-0000-000000000020"),
            selectors: selector, observations: Self.observations(surfaces: [.codexCLI]))
        let second = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home,
            deviceID: Self.object("00000000-0000-0000-0000-000000000021"),
            selectors: selector, observations: Self.observations(surfaces: [.codexCLI]))
        #expect(first[0].canonicalDirectory == second[0].canonicalDirectory)
        #expect(first[0].target.physicalDestinationID != second[0].target.physicalDestinationID)
    }

    @Test func missingDestinationDirectoriesAreObservedWithoutCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let captured = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home, deviceID: Self.object("00000000-0000-0000-0000-000000000030"),
            selectors: Self.selectors(scope: .user), observations: Self.observations())
        #expect(captured.count == 3)
        let canonicalHome = try Self.canonicalExistingDirectory(fixture.home)
        for item in captured {
            #expect(!FileManager.default.fileExists(atPath: item.plannedDirectory.path))
            let clientFolder = item.plannedDirectory.deletingLastPathComponent().lastPathComponent
            #expect(item.canonicalDirectory.path == canonicalHome.appending(path: "\(clientFolder)/skills").path)
        }
    }

    @Test func nonDirectoryAndDanglingDestinationLinksFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let claude = fixture.home.appending(path: ".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: false)
        try Data("file".utf8).write(to: claude.appending(path: "skills"))
        await #expect(throws: WorkspaceSkillTargetCaptureError.unreadableDirectory) {
            _ = try await WorkspaceSkillTargetCapture.capture(
                homeURL: fixture.home, deviceID: Self.object("00000000-0000-0000-0000-000000000031"),
                selectors: [.init(surface: .claudeCode, scope: .user)],
                observations: Self.observations(surfaces: [.claudeCode]))
        }
        try FileManager.default.removeItem(at: claude.appending(path: "skills"))
        try FileManager.default.createSymbolicLink(
            at: claude.appending(path: "skills"),
            withDestinationURL: fixture.container.appending(path: "absent"))
        await #expect(throws: WorkspaceSkillTargetCaptureError.unreadableDirectory) {
            _ = try await WorkspaceSkillTargetCapture.capture(
                homeURL: fixture.home, deviceID: Self.object("00000000-0000-0000-0000-000000000031"),
                selectors: [.init(surface: .claudeCode, scope: .user)],
                observations: Self.observations(surfaces: [.claudeCode]))
        }
    }

    @Test func rejectsMissingDuplicateUnsupportedAndMissingProjectEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let deviceID = Self.object("00000000-0000-0000-0000-000000000040")
        await #expect(throws: WorkspaceSkillTargetCaptureError.missingObservation(.codexCLI)) {
            _ = try await WorkspaceSkillTargetCapture.capture(
                homeURL: fixture.home, deviceID: deviceID,
                selectors: [.init(surface: .codexCLI, scope: .user)], observations: [])
        }
        await #expect(throws: WorkspaceSkillTargetCaptureError.ambiguousObservation(.codexCLI)) {
            _ = try await WorkspaceSkillTargetCapture.capture(
                homeURL: fixture.home, deviceID: deviceID,
                selectors: [.init(surface: .codexCLI, scope: .user)],
                observations: Self.observations(surfaces: [.codexCLI, .codexCLI]))
        }
        await #expect(throws: WorkspaceSkillTargetCaptureError.unsupportedSurface(.codexDesktop)) {
            _ = try await WorkspaceSkillTargetCapture.capture(
                homeURL: fixture.home, deviceID: deviceID,
                selectors: [.init(surface: .codexDesktop, scope: .user)], observations: [])
        }
        let missingProject = Self.artifactID("00000000-0000-0000-0000-000000000041")
        await #expect(throws: WorkspaceSkillTargetCaptureError.missingProject(missingProject)) {
            _ = try await WorkspaceSkillTargetCapture.capture(
                homeURL: fixture.home, deviceID: deviceID,
                selectors: [.init(surface: .codexCLI, scope: .project, logicalProjectID: missingProject)],
                observations: Self.observations(surfaces: [.codexCLI]))
        }
    }

    @Test func capturedRouteDoesNotManufactureCapabilityAndNilVersionBlocks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let deviceID = Self.object("00000000-0000-0000-0000-000000000050")
        let artifact = Self.artifactID("00000000-0000-0000-0000-000000000051")
        let target = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home, deviceID: deviceID,
            selectors: [.init(surface: .codexCLI, scope: .user)],
            observations: [Self.observation(.codexCLI, version: nil)])
        let contribution = AssignmentContribution(
            artifactID: artifact, destination: .init(surface: .codexCLI, scope: .user), reason: .manual)
        let resolution = WorkspaceAssignmentResolver.resolve(
            artifacts: [.init(
                identity: .init(id: artifact, kind: .skill, displayName: "Skill"),
                authority: .centralPersonal)],
            contributions: [contribution], currentDeviceID: deviceID,
            targets: target.map(\.target), capabilityEvidence: [])
        #expect(resolution.requirements.isEmpty)
        #expect(resolution.issues.map(\.kind) == [.invalidResolvedTarget])

        let versioned = try await WorkspaceSkillTargetCapture.capture(
            homeURL: fixture.home, deviceID: deviceID,
            selectors: [.init(surface: .codexCLI, scope: .user)],
            observations: Self.observations(surfaces: [.codexCLI]))
        let missingCapability = WorkspaceAssignmentResolver.resolve(
            artifacts: [.init(
                identity: .init(id: artifact, kind: .skill, displayName: "Skill"),
                authority: .centralPersonal)],
            contributions: [contribution], currentDeviceID: deviceID,
            targets: versioned.map(\.target), capabilityEvidence: [])
        #expect(missingCapability.requirements.isEmpty)
        #expect(missingCapability.issues.map(\.kind) == [.missingCapabilityEvidence])
    }

    @Test func cancellationDoesNotReturnCapturedEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let roots = (0..<512).map { index in
            DeviceProjectRootBinding(
                projectID: Self.indexedArtifact(index), rootPath: fixture.project.path)
        }
        let selectors = roots.map {
            ResolvedAssignmentSelector(surface: .codexCLI, scope: .project, logicalProjectID: $0.projectID)
        }
        let home = fixture.home
        let task = Task {
            try await WorkspaceSkillTargetCapture.capture(
                homeURL: home,
                deviceID: Self.object("00000000-0000-0000-0000-000000000060"),
                selectors: selectors, projectRoots: roots,
                observations: Self.observations(surfaces: [.codexCLI]))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private struct Fixture {
        let container: URL
        let home: URL
        let project: URL
        let library: WorkspaceLibrary

        init() throws {
            container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "skill-target-capture-\(UUID().uuidString)")
            home = container.appending(path: "home")
            project = container.appending(path: "project")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            library = WorkspaceLibrary(store: try WorkspaceStore(rootURL: container.appending(path: "workspace")))
        }

        func skill(name: String, scope: ToolingScope) throws -> Skill {
            var draft = SkillDraft()
            draft.name = name
            draft.purpose = "Test route"
            draft.triggers = ["Use the route"]
            draft.negativeTrigger = "Do not use elsewhere"
            draft.scope = scope
            draft.projectRoot = scope == .project ? project.path : ""
            draft.syncClients = false
            return try library.createSkill(from: draft).skill
        }

        func remove() { try? FileManager.default.removeItem(at: container) }
    }

    private static func selectors(
        scope: ToolingScope, projectID: ArtifactID? = nil
    ) -> [ResolvedAssignmentSelector] {
        [.claudeCode, .codexCLI, .geminiCLI].map {
            .init(surface: $0, scope: scope, logicalProjectID: projectID)
        }
    }

    private static func observations(
        surfaces: [TargetSurface] = [.claudeCode, .codexCLI, .geminiCLI]
    ) -> [TargetObservation] {
        surfaces.map { observation($0) }
    }

    private static func observation(
        _ surface: TargetSurface, version: String? = "1.0"
    ) -> TargetObservation {
        .init(surface: surface, installed: true, version: version, capabilities: emptyCapabilities)
    }

    private static var emptyCapabilities: TargetCapabilities {
        .init(
            supportsPluginInstall: false, supportsProjectScope: false,
            supportsLocalMarketplace: false, supportsMCPAuthentication: false,
            supportsConnectorDiscovery: false, requiresNewSession: false,
            requiresRestart: false, supportsMachineReadableOutput: false)
    }

    private static func capabilities(surfaces: [TargetSurface]) -> [TargetCapabilityEvidence] {
        surfaces.map {
            .init(
                surface: $0, installedClientVersion: "1.0",
                adapterContractVersion: WorkspaceSkillTargetCapture.adapterContractVersion,
                component: .skill, scopes: [.user], support: .supported,
                observedAt: Date(timeIntervalSince1970: 0))
        }
    }

    private static func object(_ value: String) -> WorkspaceObjectID {
        WorkspaceObjectID(UUID(uuidString: value)!)
    }

    private static func artifactID(_ value: String) -> ArtifactID {
        ArtifactID(UUID(uuidString: value)!)
    }

    private static func indexedArtifact(_ value: Int) -> ArtifactID {
        artifactID(String(format: "00000000-0000-0000-0000-%012x", value + 1))
    }

    private static func canonicalExistingDirectory(_ url: URL) throws -> URL {
        let pointer = try #require(realpath(url.path, nil))
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }
}
