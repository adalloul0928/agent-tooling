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
        try FileManager.default.createSymbolicLink(
            at: skills.appending(path: "gone"), withDestinationURL: home(fixture).appending(path: "nowhere"))
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

    @Test func theWeeklyRunHappensOnlyWhenTheLastReviewIsStale() async throws {
        var fresh = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        fresh.review?.generatedAt = .now.addingTimeInterval(-3_600)
        let freshServices = StubSetupServices(restored: fresh, review: .success(ShellRenderFixture.setupReview(over: fresh.audit)))
        let freshFixture = try await ShellRenderFixture(setupServices: freshServices)
        defer { freshFixture.remove() }
        await freshFixture.workspace.setup.runScheduledAudit(allowsScan: true)
        await freshFixture.workspace.setup.runScheduledReviewIfDue(consent: .existingBehaviour)
        #expect(freshServices.reviewCalls.isEmpty, "an hour-old review is not redone")
        #expect(
            freshFixture.workspace.setup.checkup?.audit.generatedAt ?? .distantPast > fresh.audit.generatedAt,
            "the audit itself runs on every open")
        #expect(freshFixture.workspace.setup.checkup?.review != nil, "and keeps the review it had")

        var stale = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        stale.review?.generatedAt = .now.addingTimeInterval(-8 * 24 * 3_600)
        let staleServices = StubSetupServices(restored: stale, review: .success(ShellRenderFixture.setupReview(over: stale.audit)))
        let staleFixture = try await ShellRenderFixture(setupServices: staleServices)
        defer { staleFixture.remove() }
        await staleFixture.workspace.setup.runScheduledAudit(allowsScan: true)
        await staleFixture.workspace.setup.runScheduledReviewIfDue(consent: .existingBehaviour)
        #expect(staleServices.reviewCalls.count == 1)
        #expect(staleServices.reviewCalls.first?.purpose == .checkup)
        #expect(staleFixture.workspace.setup.isReviewDue(consent: .existingBehaviour) == false)
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
        try "---\nname: found-skill\ndescription: Found on disk\n---\nUse it.\n".write(
            to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let session = fixture.workspace.setup
        await fixture.workspace.library.refresh()
        let head = try #require(fixture.workspace.library.state?.snapshot.document.revision.id)
        _ = try fixture.store.commitMetadata(
            expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "a", count: 64),
            writerID: WorkspaceObjectID()
        ) { document in
            let id = ArtifactID()
            document.artifacts.append(
                .init(
                    identity: .init(id: id, kind: .skill, displayName: "Found Skill"), authority: .trackedOnly, declaredName: "found-skill")
            )
            return [id]
        }
        await fixture.workspace.library.refresh()

        await session.apply(.adoptSkill(path: folder.path(percentEncoded: false), client: .claude))

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let artifact = fixture.workspace.library.state?.snapshot.document.artifacts.first { $0.declaredName == "found-skill" }
        #expect(artifact?.authority == .centralPersonal)
        #expect(
            FileManager.default.fileExists(atPath: folder.appending(path: "SKILL.md").path(percentEncoded: false)),
            "the app's folder is untouched")
    }

    @Test func reviewingOneAppFetchesItsNotesAndHandsThemToTheAssistantWithTheWebAllowed() async throws {
        let restored = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"), review: false)
        let services = StubSetupServices(restored: restored, review: .success(ShellRenderFixture.setupReview(over: restored.audit)))
        services.notes[.codex] = .success([
            .init(
                client: .codex, version: "0.160.0", source: "https://github.com/openai/codex/releases/tag/rust-v0.160.0", body: "- Big one")
        ])
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let session = fixture.workspace.setup

        await session.reviewClient(.codex)

        let review = try #require(session.clientReviews[.codex])
        #expect(review.latestVersion == "0.160.0")
        #expect(review.notes.count == 1)
        #expect(review.review?.recommendations.count == 2)
        #expect(session.reviewingClient == nil)
        #expect(session.clientReviewMessage == nil, "\(session.clientReviewMessage ?? "")")
        let call = try #require(services.reviewCalls.first)
        #expect(call.purpose == .clientReview, "the review that reaches the web")
        #expect(call.focus == .codex, "about the app under review")
        #expect(call.client == .claude, "run in the assistant this Mac prefers")
        #expect(call.releaseNotes == 1, "the fetched notes are handed over")
        #expect(services.keptClientReview(.codex)?.latestVersion == "0.160.0", "kept for the next launch")

        // Notes the app cannot fetch do not stop the review; the screen is told.
        await session.reviewClient(.kiro)
        #expect(session.clientReviews[.kiro]?.review != nil)
        #expect(session.clientReviewMessage?.contains("without release notes") == true)
    }

    @Test func applyingSeveralActionsRunsThemAllReportsFailuresAndReAuditsOnce() async throws {
        let services = StubSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let skills = home(fixture).appending(path: ".claude/skills", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        for name in ["a", "b"] {
            try FileManager.default.createSymbolicLink(
                at: skills.appending(path: name), withDestinationURL: home(fixture).appending(path: "nowhere-\(name)"))
        }
        let session = fixture.workspace.setup

        await session.applyAll([
            .removeBrokenLink(path: skills.appending(path: "a").path(percentEncoded: false), client: .claude),
            .removeBrokenLink(path: home(fixture).appending(path: "Documents/not-a-skill").path(percentEncoded: false), client: .claude),
            .removeBrokenLink(path: skills.appending(path: "b").path(percentEncoded: false), client: .claude),
        ])

        #expect(session.lastApplyMessage == "2 of 3 done.")
        #expect(session.errorMessage?.hasPrefix("1 did not go through.") == true)
        #expect((try? skills.appending(path: "a").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true)
        #expect(
            (try? skills.appending(path: "b").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
            "a failure in the middle does not stop the rest")
        #expect(session.applyProgress == nil, "progress is cleared when the run ends")
        #expect(session.checkup?.audit.findings.contains { $0.kind == .brokenSkillLink } == false)
    }

    @Test func turningAServerOffWritesWhereEachAppReadsItAndSettingAKeyWritesTheSettingsFile() async throws {
        let services = StubSetupServices()
        let fixture = try await ShellRenderFixture(setupServices: services)
        defer { fixture.remove() }
        let home = home(fixture)
        try FileManager.default.createDirectory(at: home.appending(path: ".kiro/settings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try #"{"mcpServers":{"memory":{"command":"gone.sh"}}}"#.write(
            to: home.appending(path: ".kiro/settings/mcp.json"), atomically: true, encoding: .utf8)
        try "model = \"gpt-5\"\n\n[mcp_servers.slack]\n  command = \"slack\"\n".write(
            to: home.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        try #"{"projects":{"/Users/example/one":{"allowedTools":[]},"/Users/example/two":{}}}"#.write(
            to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        try #"{"model":"sonnet"}"#.write(to: home.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
        let session = fixture.workspace.setup

        await session.apply(.disableMCPServer(name: "memory", client: .kiro))
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let kiro = try #require(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: ".kiro/settings/mcp.json"))) as? [String: Any])?[
                "mcpServers"] as? [String: Any])
        #expect((kiro["memory"] as? [String: Any])?["disabled"] as? Bool == true)
        #expect((kiro["memory"] as? [String: Any])?["command"] as? String == "gone.sh", "the configuration is kept")

        await session.apply(.disableMCPServer(name: "slack", client: .codex))
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let codex = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        #expect(codex.contains("[mcp_servers.slack]\n  command = \"slack\"\n  enabled = false\n"))
        #expect(codex.hasPrefix("model = \"gpt-5\""))

        await session.apply(.disableMCPServer(name: "slack", client: .claude))
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let claude = try #require(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: ".claude.json"))) as? [String: Any])?["projects"]
                as? [String: Any])
        #expect(
            (claude["/Users/example/one"] as? [String: Any])?["disabledMcpServers"] as? [String] == ["slack"],
            "every project Claude Code knows")
        #expect((claude["/Users/example/two"] as? [String: Any])?["disabledMcpServers"] as? [String] == ["slack"])
        #expect(session.lastApplyMessage?.contains("2 projects") == true)

        await session.apply(SetupRecommendationAction.setSetting(client: .claude, key: "toolSearch", value: "true"))
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let settings = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: ".claude/settings.json"))) as? [String: Any])
        #expect(settings["toolSearch"] as? Bool == true)
        #expect(settings["model"] as? String == "sonnet")
        // Every write left the file as it was in the workspace trash: one for
        // Kiro, one for Codex, one per project edit for Claude, one for the setting.
        let trash = fixture.store.rootURL.appending(path: "trash").path(percentEncoded: false)
        let kept = try FileManager.default.subpathsOfDirectory(atPath: trash).filter { $0.hasSuffix(".json") || $0.hasSuffix(".toml") }
        #expect(kept.count == 5, "\(kept)")
    }

    /// `~/.claude.json` keeps every project's history, so it is the client
    /// configuration most likely to grow past the read limit. Turning a server
    /// off reads it bounded: one over the limit is refused by name and limit,
    /// not read whole and taken for a file with no projects, and nothing is
    /// written or copied to the trash.
    @Test func turningAServerOffInAClaudeFileOverTheLimitSaysSoAndChangesNothing() async throws {
        let fixture = try await ShellRenderFixture(setupServices: StubSetupServices())
        defer { fixture.remove() }
        let global = home(fixture).appending(path: ".claude.json")
        let limit = BoundedFileAccess.maximumConfigurationBytes
        let history = String(repeating: "x", count: limit)
        try #"{"history":"\#(history)"}"#.write(to: global, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: global)
        let session = fixture.workspace.setup

        await session.apply(.disableMCPServer(name: "slack", client: .claude))

        #expect(session.errorMessage == ConfigurationFileTooLargeError(path: ".claude.json", maximumBytes: limit).errorDescription)
        #expect(try Data(contentsOf: global) == before)
        let trash = fixture.store.rootURL.appending(path: "trash").path(percentEncoded: false)
        #expect((try? FileManager.default.subpathsOfDirectory(atPath: trash))?.isEmpty ?? true)
    }

    /// A `~/.claude.json` that is not JSON is not a Claude Code with no
    /// projects yet. Nothing is turned off, and the message says why.
    @Test func turningAServerOffInAClaudeFileThatIsNotJSONSaysSo() async throws {
        let fixture = try await ShellRenderFixture(setupServices: StubSetupServices())
        defer { fixture.remove() }
        try #"{"projects": {"/Users/example/one": "#.write(
            to: home(fixture).appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        let session = fixture.workspace.setup

        await session.apply(.disableMCPServer(name: "slack", client: .claude))

        #expect(session.errorMessage == ".claude.json could not be read as JSON, so no server was turned off.")
    }
}
