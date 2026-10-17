import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// What another Mac asked for here, and what this Mac does about it.
@Suite("Incoming from other Macs") @MainActor
struct WorkspaceIncomingSessionTests {
    /// A skill with bytes assigned to Claude Code as "every Mac": the shape an
    /// arrival has after a sync pass brought it in.
    private func arrival(in fixture: ShellRenderFixture, name: String = "arrived-skill") async throws -> ArtifactID {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("---\nname: \(name)\ndescription: d\n---\n# \(name)\n".utf8), executable: false)),
        ])
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        let id = ArtifactID()
        _ = try await fixture.workspace.service.intakeStandaloneSkill(
            .init(expectedRevisionID: head, artifactID: id, displayName: name, prepared: prepared), prepared: prepared)
        // Every Mac: deviceIDs nil. Not this Mac's own "this Mac only" shape.
        let document = try #require(try fixture.workspace.store.snapshot()).document
        let command = try WorkspaceAssignmentBatchCommand.assign(
            document: document, artifactIDs: [id], destinations: [.init(surface: .claudeCode, scope: .user)])
        _ = try await fixture.workspace.service.applyAssignmentBatch(command)
        await fixture.workspace.library.refresh()
        return id
    }

    private func folder(_ fixture: ShellRenderFixture, _ name: String) -> URL {
        fixture.home.appending(path: ".claude/skills/\(name)", directoryHint: .isDirectory)
    }

    @Test func aSharedAssignmentThisMacHasNotInstalledIsAnArrivalThatWaitsUnderAsk() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let skill = try await arrival(in: fixture)
        let incoming = fixture.workspace.incoming

        await incoming.review()

        #expect(incoming.waiting.map(\.artifactID) == [skill])
        #expect(incoming.waiting.first?.clients == [.claude])
        #expect(incoming.installedAutomatically.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder(fixture, "arrived-skill").path))

        // The press.
        await incoming.install(skill)
        #expect(incoming.waiting.isEmpty)
        #expect(incoming.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: folder(fixture, "arrived-skill").appending(path: "SKILL.md").path))
    }

    @Test func theAutomaticPolicyInstallsAnArrivalOnReview() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        var policy = fixture.workspace.device.updatePolicy
        policy.skills = .automatic
        await fixture.workspace.device.setUpdatePolicy(policy)
        _ = try await arrival(in: fixture, name: "auto-skill")

        await fixture.workspace.incoming.review()

        #expect(fixture.workspace.incoming.installedAutomatically == ["auto-skill"])
        #expect(fixture.workspace.incoming.waiting.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder(fixture, "auto-skill").appending(path: "SKILL.md").path))
    }

    @Test func anAssignmentThisMacMadeForItselfIsNotAnArrival() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("---\nname: mine\ndescription: d\n---\n# mine\n".utf8), executable: false)),
        ])
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        let id = ArtifactID()
        _ = try await fixture.workspace.service.intakeStandaloneSkill(
            .init(expectedRevisionID: head, artifactID: id, displayName: "mine", prepared: prepared), prepared: prepared)
        await fixture.workspace.library.reviewAssignments(
            artifactIDs: [id], destinations: [.init(surface: .claudeCode, scope: .user, deviceIDs: [fixture.workspace.library.deviceID])])
        await fixture.workspace.library.applyReviewedAssignments()

        await fixture.workspace.incoming.review()

        #expect(fixture.workspace.incoming.waiting.isEmpty)
        #expect(fixture.workspace.incoming.installedAutomatically.isEmpty)
    }

    @Test func aLimitedMacIsNotAskedAboutSharedArrivals() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        _ = try await fixture.workspace.service.registerDevice(.init(
            expectedRevisionID: head, deviceID: fixture.workspace.library.deviceID, name: "Limited", receivesSharedAssignments: false))
        _ = try await arrival(in: fixture, name: "not-for-me")

        await fixture.workspace.incoming.review()

        #expect(fixture.workspace.incoming.waiting.isEmpty)
        #expect(!fixture.workspace.incoming.hasWork)
    }
}

/// The surfaces the multi-Mac work added draw.
@Suite("Multi-Mac surfaces") @MainActor
struct MultiMacSurfaceRenderTests {
    @Test func theFirstLaunchChooserDraws() throws {
        try expectDrawn(FirstLaunchChooser(start: {}, join: { _, _ in }, isBusy: false, error: nil).frame(width: 900, height: 600))
        try expectDrawn(FirstLaunchChooser(start: {}, join: { _, _ in }, isBusy: true, error: "That repository holds no workspace yet.").frame(width: 900, height: 600))
    }

    @Test func thePickerOffersEveryMacWhenOtherMacsAreRegistered() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        _ = try await fixture.workspace.service.registerDevice(.init(expectedRevisionID: head, deviceID: fixture.workspace.library.deviceID, name: "Studio"))
        let head2 = try #require(try fixture.workspace.store.snapshot()?.document.revision.id)
        _ = try await fixture.workspace.service.registerDevice(.init(expectedRevisionID: head2, deviceID: WorkspaceObjectID(), name: "MacBook", receivesSharedAssignments: false))
        await fixture.workspace.library.refresh()
        let pipeline = InstallPipeline(
            deployment: fixture.workspace.deployment, device: fixture.workspace.device,
            service: fixture.workspace.service, homeRoot: fixture.home)
        try expectDrawn(
            WorkspaceAssignmentSheet(session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill], initialClients: [.claude])
                .environment(\.installPipeline, pipeline)
                .environment(\.availableClients, [.claude, .codex])
                .environment(AppNavigationState()))
        try expectDrawn(
            WorkspaceAssignmentSheet(
                session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill], initialClients: [.claude],
                initialDevices: [fixture.workspace.library.deviceID])
                .environment(\.installPipeline, pipeline)
                .environment(\.availableClients, [.claude, .codex])
                .environment(AppNavigationState()))
    }

    @Test func theOtherMacSheetDrawsWithoutAReport() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let other = DeviceRecord(id: WorkspaceObjectID(), name: "MacBook Pro", receivesSharedAssignments: false, lastSeenAt: .now)
        try expectDrawn(OtherMacSheet(workspace: fixture.workspace, device: other))
    }

    @Test func theShellDrawsHomeAndSettingsWithTheNewSurfaces() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try expectDrawn(
            AppShellView(workspace: fixture.workspace, initialSection: .overview, navigation: AppNavigationState())
                .environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: []))
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
        try expectDrawn(
            AppShellView(workspace: fixture.workspace, initialSection: .settings, navigation: AppNavigationState())
                .environment(\.operationReceiptReader, StubOperationReceiptReader(receipts: []))
                .frame(width: shellWindowSize.width, height: shellWindowSize.height))
    }
}
