import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Reading, writing and checking one skill's files.
///
/// Every one of these goes through the injected service, so none of them opens
/// a content store, runs `git`, or reaches the network.
@Suite("Skill content session")
@MainActor
struct SkillContentSessionTests {
    @Test func creatingASkillAdmitsItAndAssignsNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let service = RecordingSkillContentService()
        let session = fixture.contentSession(content: service)

        var draft = SkillDraft()
        draft.name = "Release Readiness"
        draft.purpose = "Check whether a release is ready to ship."
        draft.triggers = ["check release readiness", "", ""]
        draft.negativeTrigger = "Building an unrelated feature"
        draft.includeScript = true

        #expect(await session.create(from: draft))
        #expect(session.errorMessage == nil)
        #expect(session.lastCreatedName == "Release Readiness")

        let admitted = try #require(service.admitted.first)
        #expect(admitted.name == "Release Readiness")
        // The name is normalized before it becomes a file name, and the script
        // template only appears because it was asked for.
        let definition = try #require(SkillContentSession.definition(in: admitted.tree))
        #expect(definition.contains("name: release-readiness"))
        #expect(definition.contains("- check release readiness"))
        #expect(admitted.tree.entries.contains { $0.relativePath == "scripts/helper.sh" })
        #expect(!admitted.tree.entries.contains { $0.relativePath.hasPrefix("references/") })
        // Creating a skill records no placement anywhere.
        #expect(fixture.workspace.library.state?.library.rows.allSatisfy { $0.requestedAssignments.isEmpty } == true)
    }

    @Test func aNameThatCouldNotBeAFolderIsRefusedBeforeAnythingIsWritten() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let service = RecordingSkillContentService()
        let session = fixture.contentSession(content: service)

        var draft = SkillDraft()
        draft.name = "../escape"
        draft.purpose = "Anything."
        draft.triggers = ["a trigger", "", ""]
        draft.negativeTrigger = "something else"

        #expect(await session.create(from: draft) == false)
        #expect(service.admitted.isEmpty)
        #expect(session.errorMessage != nil)
    }

    /// Only a skill this library maintains can be replaced. Everything else is
    /// somebody else's copy, and the command would refuse it anyway.
    @Test func onlyAPersonalSkillsSourceCanBeSaved() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let service = RecordingSkillContentService()
        let session = fixture.contentSession(content: service)
        let tracked = SkillEntry(
            id: ArtifactID(), displayName: "Bundled Skill", declaredName: "bundled", summary: "",
            ownership: .nativeOwned, authority: .nativeOwned,
            contentDigest: .init(value: String(repeating: "a", count: 64)), parentID: ArtifactID(),
            parentPluginLabel: "Example Plugin", providerPluginID: "example@vendor", sourceLabel: nil,
            requestedAssignments: [], isAssignable: true, assignmentExplanation: nil)

        #expect(await session.saveSource("# anything", for: tracked) == false)
        #expect(service.replaced.isEmpty)
    }

    /// A check says what the repository publishes and changes nothing. Applying
    /// it is the separate decision, and it is the fetched content that lands.
    @Test func checkingARepositoryReportsWithoutChangingAnything() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let service = RecordingSkillContentService()
        let session = fixture.contentSession(content: service)
        let published = try StubSkillContentService.tree()
        service.upstreamTree = published
        let followed = SkillEntry(
            id: ArtifactID(), displayName: "Release Readiness", declaredName: "release-readiness", summary: "",
            ownership: .centralUpstream, authority: .centralUpstream(subscriptionID: WorkspaceObjectID()),
            contentDigest: .init(value: String(repeating: "b", count: 64)), parentID: nil,
            parentPluginLabel: nil, providerPluginID: nil, sourceLabel: "github.com/acme/skills",
            requestedAssignments: [], isAssignable: true, assignmentExplanation: nil)
        let binding = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/acme/skills", ref: "main", subdirectory: "skills/release-readiness")

        await session.checkUpstream(for: followed, binding: binding)
        #expect(session.errorMessage == nil)
        #expect(session.upstreamStatus?.isUpToDate == false)
        #expect(service.fetched == ["https://github.com/acme/skills"])
        #expect(service.replaced.isEmpty)

        // The same content the workspace already approved is up to date, and
        // offers nothing to review.
        let current = SkillEntry(
            id: followed.id, displayName: followed.displayName, declaredName: followed.declaredName,
            summary: "", ownership: .centralUpstream, authority: followed.authority,
            contentDigest: published.digest, parentID: nil, parentPluginLabel: nil, providerPluginID: nil,
            sourceLabel: followed.sourceLabel, requestedAssignments: [], isAssignable: true,
            assignmentExplanation: nil)
        await session.checkUpstream(for: current, binding: binding)
        #expect(session.upstreamStatus?.isUpToDate == true)
    }

    @Test func aRepositoryThatCannotBeReachedSaysSoAndClaimsNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let service = RecordingSkillContentService()
        service.upstreamFailure = SkillRepositoryError.unavailable
        let session = fixture.contentSession(content: service)
        let followed = SkillEntry(
            id: ArtifactID(), displayName: "Release Readiness", declaredName: "release-readiness", summary: "",
            ownership: .centralUpstream, authority: .centralUpstream(subscriptionID: WorkspaceObjectID()),
            contentDigest: .init(value: String(repeating: "b", count: 64)), parentID: nil,
            parentPluginLabel: nil, providerPluginID: nil, sourceLabel: nil,
            requestedAssignments: [], isAssignable: true, assignmentExplanation: nil)

        await session.checkUpstream(
            for: followed,
            binding: try SkillRepositoryBinding(repositoryURL: "https://github.com/acme/skills"))
        #expect(session.upstreamStatus == nil)
        #expect(session.errorMessage != nil)
        #expect(await session.applyUpstream(for: followed) == false)
    }
}

/// A content service that keeps what it was asked to do, so a test can check
/// that a screen asked for exactly that and nothing more.
final class RecordingSkillContentService: SkillContentServing, @unchecked Sendable {
    struct Admission {
        let tree: CapturedPackageTree
        let name: String
    }

    private let lock = NSLock()
    private var _admitted: [Admission] = []
    private var _replaced: [ArtifactID] = []
    private var _fetched: [String] = []
    private var _upstreamTree: CapturedPackageTree?
    private var _upstreamFailure: (any Error)?

    var admitted: [Admission] { lock.withLock { _admitted } }
    var replaced: [ArtifactID] { lock.withLock { _replaced } }
    var fetched: [String] { lock.withLock { _fetched } }
    var upstreamTree: CapturedPackageTree? {
        get { lock.withLock { _upstreamTree } }
        set { lock.withLock { _upstreamTree = newValue } }
    }
    var upstreamFailure: (any Error)? {
        get { lock.withLock { _upstreamFailure } }
        set { lock.withLock { _upstreamFailure = newValue } }
    }

    func read(
        artifactID: ArtifactID, revisionID: WorkspaceObjectID,
        through service: WorkspaceApplicationService
    ) async throws -> WorkspaceSkillContentSnapshot {
        let tree = try StubSkillContentService.tree()
        return .init(
            revisionID: revisionID,
            artifact: .init(
                identity: .init(id: artifactID, kind: .skill, displayName: "Standalone Skill"),
                authority: .centralPersonal, declaredName: "standalone-skill", contentDigest: tree.digest),
            tree: tree)
    }

    func replace(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        lock.withLock { _replaced.append(artifactID) }
    }

    func admit(
        _ tree: CapturedPackageTree, named displayName: String,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        lock.withLock { _admitted.append(.init(tree: tree, name: displayName)) }
    }

    func upstream(_ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL) async throws -> PreparedStandaloneSkill {
        lock.withLock { _fetched.append(binding.repositoryURL) }
        if let failure = upstreamFailure { throw failure }
        return try WorkspaceSkillPreparation.personal(tree: upstreamTree ?? StubSkillContentService.tree())
    }
}
