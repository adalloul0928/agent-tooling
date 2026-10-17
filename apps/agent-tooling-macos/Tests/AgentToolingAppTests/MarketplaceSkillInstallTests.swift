import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Install on a registry skill listing: the skill is fetched from its
/// repository and kept as a followed skill, so the picker has a row to work on.
private let fakeRevision = String(repeating: "b", count: 40)

@MainActor
struct MarketplaceSkillInstallTests {

    private func listing(_ repository: String, _ skill: String) -> MarketplacePackage {
        MarketplacePackage(
            id: "skills-sh:\(repository)/\(skill)", name: skill, publisher: String(repository.split(separator: "/")[0]),
            summary: "s", sourceName: "skills.sh", components: [.skill], supportedClients: Set(ClientKind.allCases),
            trustSummary: "t", location: "https://skills.sh/\(repository)/\(skill)",
            provenance: PackageProvenance(
                source: PackageSource(kind: .skillsShRegistry, location: "https://github.com/\(repository)"),
                publisher: String(repository.split(separator: "/")[0])),
            installCount: 10)
    }

    /// A stand-in for the repository: knows two skills under acme/marketing.
    private func session(_ fixture: ShellRenderFixture, found: Set<String>) -> WorkspaceMarketplaceSession {
        WorkspaceMarketplaceSession(
            providers: [], service: fixture.workspace.service, library: fixture.workspace.library, store: fixture.store,
            locateSkill: { skillID, repositoryURL, _ in
                guard found.contains(skillID) else { throw SkillRepositoryError.sourceMissing }
                return try SkillRepositoryBinding(repositoryURL: repositoryURL, ref: "main", subdirectory: "skills/\(skillID)")
            },
            fetchSkill: { binding, _ in
                let name = binding.subdirectory.split(separator: "/").last.map(String.init) ?? "skill"
                let tree = try CapturedPackageTree(entries: [
                    .init(
                        relativePath: "SKILL.md",
                        kind: .file(bytes: Data("---\nname: \(name)\ndescription: d\n---\n# \(name)\n".utf8), executable: false))
                ])
                return try PreparedStandaloneSkill(
                    tree: tree,
                    upstream: .init(
                        repositoryURL: binding.repositoryURL, requestedRef: binding.ref,
                        revision: .init(kind: .gitCommitSHA1, value: fakeRevision),
                        packageRelativePath: binding.subdirectory, publisherID: "github:acme"))
            })
    }

    @Test func installingARegistrySkillKeepsItAsAFollowedSkillThePickerCanOpen() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = session(fixture, found: ["ab-testing", "seo-audit"])
        let package = listing("acme/marketing", "ab-testing")
        await fixture.workspace.library.refresh()
        #expect(session.libraryMatch(for: package) == nil)

        await session.adoptSkill(package)

        let match = try #require(session.libraryMatch(for: package))
        #expect(match.displayName == "ab-testing")
        #expect(session.adoption?.message.contains("following its main branch") == true)
        let document = try #require(try fixture.store.snapshot()).document
        let row = try #require(document.artifacts.first { $0.identity.id == match.artifactID })
        guard case .centralUpstream(let subscriptionID) = row.authority else {
            Issue.record("expected a followed skill, got \(row.authority)")
            return
        }
        let subscription = try #require(document.subscriptions.first { $0.id == subscriptionID })
        #expect(subscription.lock.packageRelativePath == "skills/ab-testing")
        #expect(document.sources.first { $0.id == subscription.sourceID }?.repositoryURL == "https://github.com/acme/marketing")

        // A second skill from the same repository shares its source record.
        await session.adoptSkill(listing("acme/marketing", "seo-audit"))
        let after = try #require(try fixture.store.snapshot()).document
        #expect(after.sources.count { $0.repositoryURL == "https://github.com/acme/marketing" } == 1)
        #expect(session.libraryMatch(for: listing("acme/marketing", "seo-audit")) != nil)
        // And the listing identity survives a cold re-read of the document.
        let fresh = self.session(fixture, found: [])
        await fresh.refresh()
        #expect(fresh.libraryMatch(for: package)?.artifactID == match.artifactID)
    }

    @Test func aSkillTheRepositoryDoesNotHaveIsRefusedInPlainWords() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = session(fixture, found: [])
        let package = listing("acme/marketing", "missing")
        await fixture.workspace.library.refresh()

        await session.adoptSkill(package)

        #expect(session.libraryMatch(for: package) == nil)
        #expect(session.adoption?.packageID == package.id)
        #expect(session.adoption?.message == "The repository has no skill by that name on its default branch. Nothing was added.")
    }
}
