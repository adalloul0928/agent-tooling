import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Following a repository, from the Skills screen.
///
/// The fetch is scripted in every one of these, so none of them runs `git` or
/// reaches the network. The write is not: linking goes through the workspace's
/// own command against the fixture's real store, because what this screen has
/// to be right about is the record that lands.
@Suite("Skill upstream linking")
@MainActor
struct SkillUpstreamLinkSessionTests {
    @Test func linkingMatchingBytesRecordsTheRepositoryAndLeavesTheContentAlone() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let held = try await fixture.holdPersonalSkill()
        let linker = ScriptedSkillUpstreamLinker(publishing: held.tree)
        let session = SkillUpstreamLinkSession(workspace: fixture.workspace, linker: linker)
        session.repositoryURL = "https://github.com/publisher/skills"
        session.subdirectory = "skills/release-readiness"

        await session.check(for: held.entry)
        #expect(session.errorMessage == nil)
        #expect(linker.fetches == ["https://github.com/publisher/skills"])
        #expect(session.checked?.matchesLibrary == true)
        #expect(session.checked?.revision.value == String(repeating: "a", count: 40))
        #expect(session.canLink)

        #expect(await session.link(held.entry))
        let document = try #require(fixture.workspace.library.state?.snapshot.document)
        let artifact = try #require(document.artifacts.first { $0.identity.id == held.entry.id })
        let subscription = try #require(document.subscriptions.first)
        #expect(artifact.authority == .centralUpstream(subscriptionID: subscription.id))
        #expect(artifact.contentDigest == held.tree.digest)
        #expect(subscription.lock.approvedContent == held.tree.digest)
        #expect(document.sources.first?.repositoryURL == "https://github.com/publisher/skills")
        #expect(linker.adopted.isEmpty)

        // And the section now reads the binding back out of the document, which
        // is what turns the checking pair on for this row.
        let followed = try #require(fixture.entry(for: held.entry.id))
        let resolved = try #require(SkillUpstreamBinding.resolve(followed, in: document))
        #expect(resolved.binding.repositoryURL == "https://github.com/publisher/skills")
        #expect(resolved.binding.subdirectory == "skills/release-readiness")
        #expect(resolved.approvedRevision.value == String(repeating: "a", count: 40))
    }

    @Test func aSkillWithLocalEditsIsToldWhyAndItsEditsAreUntouched() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let held = try await fixture.holdPersonalSkill(body: "What this Mac holds")
        let published = try ShellRenderFixture.skillTree(body: "What the repository publishes")
        let session = SkillUpstreamLinkSession(
            workspace: fixture.workspace, linker: ScriptedSkillUpstreamLinker(publishing: published))
        session.repositoryURL = "https://github.com/publisher/skills"
        session.subdirectory = "skills/release-readiness"

        await session.check(for: held.entry)
        #expect(session.checked?.matchesLibrary == false)
        #expect(!session.canLink)
        #expect(await session.link(held.entry) == false)

        let document = try #require(fixture.workspace.library.state?.snapshot.document)
        #expect(document.subscriptions.isEmpty)
        #expect(document.sources.isEmpty)
        #expect(document.artifacts.first { $0.identity.id == held.entry.id }?.contentDigest == held.tree.digest)
        #expect(document.artifacts.first { $0.identity.id == held.entry.id }?.authority == .centralPersonal)
    }

    /// The other honest route: take the repository's version as a reviewed
    /// content change, stay personal, and only then follow it.
    @Test func takingTheRepositoryVersionIsAContentChangeThatLeavesTheSkillPersonal() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let held = try await fixture.holdPersonalSkill(body: "What this Mac holds")
        let published = try ShellRenderFixture.skillTree(body: "What the repository publishes")
        let linker = ScriptedSkillUpstreamLinker(publishing: published)
        let session = SkillUpstreamLinkSession(workspace: fixture.workspace, linker: linker)
        session.repositoryURL = "https://github.com/publisher/skills"
        session.subdirectory = "skills/release-readiness"
        await session.check(for: held.entry)

        #expect(await session.takeRepositoryVersion(held.entry))
        let updated = try #require(fixture.workspace.library.state?.snapshot.document)
        let artifact = try #require(updated.artifacts.first { $0.identity.id == held.entry.id })
        #expect(artifact.contentDigest == published.digest)
        // Taking the content is not taking ownership: that stays a decision.
        #expect(artifact.authority == .centralPersonal)
        #expect(updated.subscriptions.isEmpty)
        #expect(linker.fetches.count == 1)

        // The same review can now be followed without asking the repository a
        // second time, and the row the screen holds is the stale one.
        #expect(session.checked?.matchesLibrary == true)
        #expect(await session.link(held.entry))
        let followed = try #require(fixture.workspace.library.state?.snapshot.document)
        #expect(followed.subscriptions.first?.lock.approvedContent == published.digest)
        #expect(linker.fetches.count == 1)
    }

    @Test func aRepositoryThatCannotBeReachedSaysSoAndClaimsNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let held = try await fixture.holdPersonalSkill()
        let linker = ScriptedSkillUpstreamLinker(publishing: held.tree)
        linker.failure = SkillRepositoryError.unavailable
        let session = SkillUpstreamLinkSession(workspace: fixture.workspace, linker: linker)
        session.repositoryURL = "https://github.com/publisher/skills"

        await session.check(for: held.entry)
        #expect(session.checked == nil)
        #expect(session.errorMessage == SkillRepositoryError.unavailable.errorDescription)
        #expect(!session.canLink)
        #expect(fixture.workspace.library.state?.snapshot.document.sources.isEmpty == true)
    }

    /// A skill that is not the person's own never reaches the command, and the
    /// refusal it would get is the one the screen would have to show.
    @Test func aSkillThatIsNotYoursCannotBeFollowed() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let held = try await fixture.holdPersonalSkill()
        let bundled = try #require(fixture.entry(for: ShellRenderFixture.child))
        #expect(bundled.ownership == .nativeOwned)
        #expect(!bundled.hasCentralContent)
        let session = SkillUpstreamLinkSession(
            workspace: fixture.workspace, linker: ScriptedSkillUpstreamLinker(publishing: held.tree))
        session.repositoryURL = "https://github.com/publisher/skills"

        await session.check(for: bundled)
        #expect(session.checked?.matchesLibrary == false)
        #expect(!session.canLink)
        #expect(await session.link(bundled) == false)
        #expect(fixture.workspace.library.state?.snapshot.document.subscriptions.isEmpty == true)
    }

    // MARK: - What the screen draws

    @Test func theInspectorDrawsTheAffordanceAndFetchesNothingToDoIt() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences()
        defer { preferences.remove() }
        let held = try await fixture.holdPersonalSkill()
        let linker = ScriptedSkillUpstreamLinker(publishing: held.tree)
        let navigation = AppNavigationState()
        navigation.open(.skill(held.entry.id.rawValue.uuidString.lowercased()))

        try Self.keep(
            try rasterize(
                SkillsView(workspace: fixture.workspace, content: fixture.contentSession())
                    .environment(navigation)
                    .environment(\.skillContentService, StubSkillContentService())
                    .environment(\.skillUpstreamLinker, linker)
                    .environment(\.availableClients, ClientKind.allCases)
                    .defaultAppStorage(preferences.defaults)), "inspector")

        // Drawing the row must not ask a repository anything. A screen that
        // fetched to decide what to draw would run `git` on somebody's Mac
        // before they asked for it.
        #expect(linker.fetches.isEmpty)
        #expect(linker.linked.isEmpty)
    }

    @Test func theSheetDrawsInEveryStateItCanBeIn() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let held = try await fixture.holdPersonalSkill(body: "What this Mac holds")
        let published = try ShellRenderFixture.skillTree(body: "What the repository publishes")
        let session = SkillUpstreamLinkSession(
            workspace: fixture.workspace, linker: ScriptedSkillUpstreamLinker(publishing: published))

        try Self.keep(try rasterize(SkillUpstreamLinkSheet(skill: held.entry, session: session)), "sheet-empty")
        session.repositoryURL = "https://github.com/publisher/skills"
        session.subdirectory = "skills/release-readiness"
        await session.check(for: held.entry)
        #expect(session.checked?.matchesLibrary == false)
        try Self.keep(try rasterize(SkillUpstreamLinkSheet(skill: held.entry, session: session)), "sheet-differs")

        let matching = SkillUpstreamLinkSession(
            workspace: fixture.workspace, linker: ScriptedSkillUpstreamLinker(publishing: held.tree))
        matching.repositoryURL = "https://github.com/publisher/skills"
        matching.subdirectory = "skills/release-readiness"
        await matching.check(for: held.entry)
        #expect(matching.checked?.matchesLibrary == true)
        try Self.keep(try rasterize(SkillUpstreamLinkSheet(skill: held.entry, session: matching)), "sheet-matches")
    }

    /// Set `SKILL_UPSTREAM_LINK_CAPTURE` to a path prefix to keep the frames,
    /// which is how these are looked at rather than only asserted about.
    private static func keep(
        _ bitmap: NSBitmapImageRep, _ label: String, _ location: SourceLocation = #_sourceLocation
    ) throws {
        #expect(distinctColours(in: bitmap) > 4, "the screen drew a blank frame", sourceLocation: location)
        guard let destination = ProcessInfo.processInfo.environment["SKILL_UPSTREAM_LINK_CAPTURE"],
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try png.write(to: URL(fileURLWithPath: "\(destination)-\(label).png"))
    }
}

/// One repository's answer, scripted. The fetch never leaves memory; the two
/// writes go through the workspace's own commands, because the record they
/// leave is the thing worth testing.
@MainActor
final class ScriptedSkillUpstreamLinker: SkillUpstreamLinking {
    private let published: CapturedPackageTree
    private let revision: String
    private let live = LiveSkillUpstreamLinker()
    var failure: (any Error)?
    private(set) var fetches: [String] = []
    private(set) var linked: [ArtifactID] = []
    private(set) var adopted: [ArtifactID] = []

    init(publishing tree: CapturedPackageTree, revision: String = String(repeating: "a", count: 40)) {
        self.published = tree
        self.revision = revision
    }

    nonisolated func fetch(
        _ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL
    ) async throws -> PreparedStandaloneSkill {
        try await record(binding)
    }

    nonisolated func link(
        _ command: LinkSkillUpstreamCommand, prepared: PreparedStandaloneSkill,
        through service: WorkspaceApplicationService
    ) async throws {
        await MainActor.run { linked.append(command.artifactID) }
        try await live.link(command, prepared: prepared, through: service)
    }

    nonisolated func adopt(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {
        await MainActor.run { adopted.append(artifactID) }
        try await live.adopt(tree, of: artifactID, expecting: digest, at: revisionID, through: service)
    }

    private func record(_ binding: SkillRepositoryBinding) throws -> PreparedStandaloneSkill {
        fetches.append(binding.repositoryURL)
        if let failure { throw failure }
        return try PreparedStandaloneSkill(
            tree: published,
            upstream: .init(
                repositoryURL: binding.repositoryURL, requestedRef: binding.ref,
                revision: .init(kind: .gitCommitSHA1, value: revision),
                packageRelativePath: binding.subdirectory.isEmpty ? "." : binding.subdirectory,
                publisherID: "github:publisher"))
    }
}

extension ShellRenderFixture {
    /// One skill this library actually holds the bytes of.
    ///
    /// The shared fixture's standalone skill records no content, which is the
    /// ordinary shape of a scanned workspace and the one that must say so
    /// rather than offer a button. Following a repository needs the other one.
    func holdPersonalSkill(
        body: String = "What both sides have", displayName: String = "Release Readiness"
    ) async throws -> (entry: SkillEntry, tree: CapturedPackageTree) {
        let tree = try Self.skillTree(body: body)
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        guard let head = workspace.library.state?.snapshot.document.revision.id else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        let artifactID = ArtifactID()
        _ = try await workspace.service.intakeStandaloneSkill(
            .init(
                expectedRevisionID: head, artifactID: artifactID, displayName: displayName,
                prepared: prepared), prepared: prepared)
        await workspace.library.refresh()
        guard let entry = entry(for: artifactID) else { throw WorkspaceRevisionStoreError.missingArtifact }
        return (entry, tree)
    }

    /// The row the Skills screen would show for one artifact.
    func entry(for artifactID: ArtifactID) -> SkillEntry? {
        SkillInventoryIndex(
            library: workspace.library.state?.library, snapshot: workspace.library.state?.snapshot,
            observations: workspace.device.observations, ownershipJSON: "{}"
        ).skills.first { $0.id == artifactID }
    }

    static func skillTree(body: String = "What both sides have") throws -> CapturedPackageTree {
        try CapturedPackageTree(entries: [
            .init(
                relativePath: "SKILL.md",
                kind: .file(
                    bytes: Data(
                        """
                        ---
                        name: release-readiness
                        description: Check whether a release is ready to ship.
                        ---

                        # Release Readiness

                        \(body)
                        """.utf8), executable: false))
        ])
    }
}
