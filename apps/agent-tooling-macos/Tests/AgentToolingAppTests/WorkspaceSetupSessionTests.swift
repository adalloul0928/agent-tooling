import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The checkup: audit, review, dismiss, apply, and the weekly run.
@Suite("Checkup session")
@MainActor
struct WorkspaceSetupSessionTests {
    private func home(_ fixture: ShellRenderFixture) -> URL { fixture.workspace.homeRoot }

    @Test func anAuditProducesFindingsFromTheLastCheckAndKeepsThem() async throws {
        let services = StubSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        // Plant a broken link where the audit looks.
        let skills = home(fixture).appending(path: ".claude/skills", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skills.appending(path: "gone"), withDestinationURL: home(fixture).appending(path: "nowhere"))
        let session = fixture.workspace.setup

        await session.audit()

        let checkup = try #require(session.checkup)
        #expect(checkup.audit.findings.contains { $0.kind == .brokenSkillLink && $0.subject == "gone" })
        #expect(services.keptCheckup?.audit.findings.count == checkup.audit.findings.count, "kept for the next launch")
        #expect(session.isAuditing == false)
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
    }

    @Test func aReviewJoinsTheCheckupAndIsKeptAndAFailedOneSaysWhy() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"), review: false)
        let services = StubSetupServices(restored: restored, review: .success(ShellRenderFixture.setupReview(over: restored.audit)))
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let session = fixture.workspace.setup
        #expect(session.checkup?.review == nil)

        await session.review(purpose: .checkup)

        #expect(session.reviewMessage == nil)
        #expect(session.checkup?.review?.recommendations.count == 2)
        #expect(services.reviewCalls.first?.purpose == .checkup)
        #expect(services.reviewCalls.first?.client == .claude, "Claude Code is preferred when this Mac has it")
        #expect(services.keptCheckup?.review != nil)

        let failing = StubSetupServices(restored: restored, review: .failure(SetupReviewError.clientFailed(.claude, 1, "401 Unauthorized")))
        let other = try await ShellRenderFixture(setupServices: failing)
        defer { other.remove() }
        await other.workspace.setup.review(purpose: .checkup)
        #expect(other.workspace.setup.reviewMessage?.contains("401 Unauthorized") == true)
        #expect(other.workspace.setup.checkup?.review == nil, "a failed review leaves the audit alone")
    }

    @Test func dismissingHidesAFindingUntilItIsBroughtBack() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        let services = StubSetupServices(restored: restored)
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let session = fixture.workspace.setup
        let finding = try #require(session.checkup?.audit.findings.first)
        let recommendation = try #require(session.checkup?.review?.recommendations.first)

        session.dismiss(finding)
        session.dismiss(recommendation)
        #expect(session.checkup?.openFindings.contains { $0.id == finding.id } == false)
        #expect(session.checkup?.openRecommendations.contains { $0.id == recommendation.id } == false)
        #expect(services.keptCheckup?.dismissedFindingIDs.contains(finding.id) == true, "the dismissal survives a relaunch")

        session.undismiss(finding)
        #expect(session.checkup?.openFindings.contains { $0.id == finding.id } == true)
    }

    @Test func theWeeklyRunHappensOnlyWhenTheLastCheckupIsStale() async throws {
        var fresh = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        fresh.completedAt = .now.addingTimeInterval(-3_600)
        let freshServices = StubSetupServices(restored: fresh, review: .success(ShellRenderFixture.setupReview(over: fresh.audit)))
        let freshFixture = try await ShellRenderFixture(setupServices: freshServices)
        defer { freshFixture.remove() }
        await freshFixture.workspace.setup.runScheduledCheckupIfStale()
        #expect(freshServices.reviewCalls.isEmpty, "an hour-old checkup is not redone")

        var stale = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        stale.completedAt = .now.addingTimeInterval(-8 * 24 * 3_600)
        let staleServices = StubSetupServices(restored: stale, review: .success(ShellRenderFixture.setupReview(over: stale.audit)))
        let staleFixture = try await ShellRenderFixture(setupServices: staleServices)
        defer { staleFixture.remove() }
        await staleFixture.workspace.setup.runScheduledCheckupIfStale()
        #expect(staleServices.reviewCalls.count == 1)
        #expect(staleServices.reviewCalls.first?.purpose == .checkup)
        #expect(staleFixture.workspace.setup.isStale == false)
    }

    @Test func applyingRemovesABrokenLinkAndReAudits() async throws {
        let services = StubSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let skills = home(fixture).appending(path: ".claude/skills", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let link = skills.appending(path: "gone")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home(fixture).appending(path: "nowhere"))
        let session = fixture.workspace.setup
        await session.audit()
        let finding = try #require(session.checkup?.audit.findings.first { $0.kind == .brokenSkillLink })

        await session.apply(finding.actions[0])

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect((try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true, "the link is gone")
        #expect(session.checkup?.audit.findings.contains { $0.id == finding.id } == false, "the re-audit no longer reports it")
        #expect(session.lastApplyMessage?.contains("Removed") == true)
    }

    @Test func applyingAdoptsATrackedSkillIntoTheLibrary() async throws {
        let services = StubSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        // A skill on disk that the library only tracks.
        let folder = home(fixture).appending(path: ".claude/skills/found-skill", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: found-skill\ndescription: Found on disk\n---\nUse it.\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let session = fixture.workspace.setup
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        _ = try fixture.store.commitMetadata(
            expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "a", count: 64),
            writerID: WorkspaceObjectID()
        ) { document in
            let id = ArtifactID()
            document.artifacts.append(.init(identity: .init(id: id, kind: .skill, displayName: "Found Skill"), authority: .trackedOnly, declaredName: "found-skill"))
            return [id]
        }
        await fixture.workspace.library.refresh()

        await session.apply(.adoptSkill(path: folder.path(percentEncoded: false), client: .claude))

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let artifact = fixture.workspace.library.state?.snapshot.document.artifacts.first { $0.declaredName == "found-skill" }
        #expect(artifact?.authority == .centralPersonal)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "SKILL.md").path(percentEncoded: false)), "the app's folder is untouched")
    }
}
