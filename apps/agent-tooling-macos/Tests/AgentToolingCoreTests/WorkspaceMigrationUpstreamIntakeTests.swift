import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceMigrationUpstreamIntakeTests {
    @Test func choosesEitherRecordedFolderWithTheSameStableSourceAndSubscriptionIDs() throws {
        let skill = try upstreamSkill(paths: ["/work/A": hash("a"), "/work/B": hash("b")])
        let intake = baseIntake(skill)
        let initial = try WorkspaceMigrationUpstreamIntake.review(intake: intake, workspaceID: workspaceID)
        let candidates = try #require(initial.requirements.first?.candidates)
        let a = try #require(candidates.first { $0.directoryPath == "/work/A" })
        let b = try #require(candidates.first { $0.directoryPath == "/work/B" })
        let selectedA = try WorkspaceMigrationUpstreamIntake.review(intake: intake, workspaceID: workspaceID,
                                                                      selections: [key: a.id])
        let selectedB = try WorkspaceMigrationUpstreamIntake.review(intake: intake, workspaceID: workspaceID,
                                                                      selections: [key: b.id])
        guard case let .centralUpstream(pathA, sourceA, subscriptionA) = try #require(selectedA.intake.choices.first).strategy,
              case let .centralUpstream(pathB, sourceB, subscriptionB) = try #require(selectedB.intake.choices.first).strategy else {
            Issue.record("Selected evidence must become an upstream choice.")
            return
        }
        #expect(pathA.path == "/work/A" && pathB.path == "/work/B")
        #expect(sourceA == sourceB && subscriptionA == subscriptionB)
        let automaticSource = try WorkspaceMigrationIntake.stableID(workspaceID: workspaceID, skillID: skill.id, role: "source")
        let automaticSubscription = try WorkspaceMigrationIntake.stableID(workspaceID: workspaceID, skillID: skill.id, role: "subscription")
        #expect(sourceA == automaticSource && subscriptionA == automaticSubscription)
    }

    @Test func staleUnknownSelectionRemainsBlockedAndAllEvidenceFieldsChangeCandidateID() throws {
        let skill = try upstreamSkill(paths: ["/work/A": hash("a")])
        let intake = baseIntake(skill)
        let baseline = try WorkspaceMigrationUpstreamIntake.review(intake: intake, workspaceID: workspaceID)
        let baselineID = try #require(baseline.requirements.first?.candidates.first?.id)
        let stale = try WorkspaceMigrationUpstreamIntake.review(intake: intake, workspaceID: workspaceID, selections: [key: "stale"])
        #expect(stale.selections.isEmpty)
        #expect(stale.intake.issues.contains { $0.legacy == key && $0.reason == .upstreamInstallation })
        for changed in try evidenceVariants(of: skill) {
            let candidate = try #require(WorkspaceMigrationUpstreamIntake.review(
                intake: baseIntake(changed), workspaceID: workspaceID
            ).requirements.first?.candidates.first?.id)
            #expect(candidate != baselineID)
        }
    }

    @Test func malformedBindingHasVisibleRequirementWithoutCandidates() throws {
        var skill = try upstreamSkill(paths: ["/work/A": hash("a")])
        skill.repositoryBinding?.installedRevision = "bad"
        let reviewed = try WorkspaceMigrationUpstreamIntake.review(intake: baseIntake(skill), workspaceID: workspaceID)
        #expect(reviewed.requirements.first?.candidates.isEmpty == true)
        #expect(reviewed.requirements.first?.repositoryURL == nil)
        #expect(reviewed.intake.issues.contains { $0.reason == .upstreamInstallation })
    }

    @Test func latestCheckedRevisionCannotReplaceMissingInstalledRevision() throws {
        var skill = try upstreamSkill(paths: ["/work/A": hash("a")])
        skill.repositoryBinding?.installedRevision = nil
        skill.repositoryBinding?.lastCheckedRevision = String(repeating: "b", count: 40)
        let reviewed = try WorkspaceMigrationUpstreamIntake.review(intake: baseIntake(skill), workspaceID: workspaceID)
        #expect(reviewed.requirements.first?.candidates.isEmpty == true)
        #expect(reviewed.requirements.first?.installedRevision == nil)
        #expect(reviewed.intake.issues.contains { $0.reason == .upstreamInstallation })
    }

    @Test func nativeChildrenAreNeverSelectedAsStandaloneUpstreamSkills() throws {
        let skill = try upstreamSkill(paths: ["/work/A": hash("a")])
        let intake = WorkspaceMigrationIntake(
            choices: [],
            issues: [.init(legacy: key, displayName: skill.displayName, reason: .upstreamInstallation)],
            snapshot: .init(skills: [skill], plugins: [.init(id: "plugin", name: "Plugin", summary: "", source: "", scope: "This Mac", revision: "", skills: [skill.id], profiles: [], clients: [], installed: true)])
        )
        let reviewed = try WorkspaceMigrationUpstreamIntake.review(intake: intake, workspaceID: workspaceID,
                                                                     selections: [key: "anything"], requiringReview: [key])
        #expect(reviewed.requirements.isEmpty && reviewed.selections.isEmpty)
        #expect(reviewed.intake.choices.isEmpty)
    }

    @Test func forcedReviewRemovesFormerAutomaticChoiceWhenSourceEvidenceDisappears() throws {
        var skill = try upstreamSkill(paths: ["/work/A": hash("a")])
        skill.repositoryBinding = nil
        let automatic = WorkspaceMigrationIntake(
            choices: [.init(legacy: key, strategy: .centralPersonal)], issues: [], snapshot: .init(skills: [skill])
        )
        let reviewed = try WorkspaceMigrationUpstreamIntake.review(intake: automatic, workspaceID: workspaceID,
                                                                     requiringReview: [key])
        #expect(reviewed.requirements.first?.candidates.isEmpty == true)
        #expect(!reviewed.intake.choices.contains { $0.legacy == key })
        #expect(reviewed.intake.issues.contains { $0.legacy == key && $0.reason == .upstreamInstallation })
    }

    private let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000fed")!)
    private let key = LegacyReferenceKey(domain: .skill, identifier: "upstream")

    private func baseIntake(_ skill: Skill) -> WorkspaceMigrationIntake {
        .init(choices: [], issues: [.init(legacy: key, displayName: skill.displayName, reason: .upstreamInstallation)],
              snapshot: .init(skills: [skill]))
    }
    private func upstreamSkill(paths: [String: String]) throws -> Skill {
        var binding = try SkillRepositoryBinding(repositoryURL: "https://github.com/example/repo", ref: "main", subdirectory: "skills/upstream", installedFingerprints: paths)
        binding.installedRevision = String(repeating: "a", count: 40)
        return .init(id: "upstream", name: "upstream", displayName: "Upstream", summary: "Fixture", bundle: "standalone",
                     scope: "This Mac", owned: false, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [],
                     validationCount: 0, repositoryBinding: binding)
    }
    private func evidenceVariants(of skill: Skill) throws -> [Skill] {
        var repository = skill; repository.repositoryBinding?.repositoryURL = "https://github.com/other/repo"
        var ref = skill; ref.repositoryBinding?.ref = "release"
        var subdirectory = skill; subdirectory.repositoryBinding?.subdirectory = "other"
        var revision = skill; revision.repositoryBinding?.installedRevision = String(repeating: "b", count: 40)
        var path = skill; path.repositoryBinding?.installedFingerprints = ["/work/B": hash("a")]
        var fingerprint = skill; fingerprint.repositoryBinding?.installedFingerprints = ["/work/A": hash("b")]
        return [repository, ref, subdirectory, revision, path, fingerprint]
    }
    private func hash(_ character: Character) -> String { String(repeating: String(character), count: 64) }
}
