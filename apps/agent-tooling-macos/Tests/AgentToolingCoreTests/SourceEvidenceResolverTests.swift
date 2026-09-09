import Foundation
import Testing

@testable import AgentToolingCore

struct SourceEvidenceResolverTests {
    @Test func preservesConfirmedIntentAndRetainsDisagreementForReview() throws {
        let id = fixedID("00000000-0000-0000-0000-000000000001")
        let confirmed = ConfirmedSourceBinding(
            artifactID: id,
            repositoryURL: "HTTPS://GitHub.com/Owner/Repo.git",
            requestedRef: "main",
            packagePath: "skills/One"
        )
        let output = SourceEvidenceResolver.resolve(
            artifacts: [record(id)],
            confirmed: [confirmed],
            observations: [observation(id, url: "https://github.com/Other/Repo", path: "skills/One")]
        )

        #expect(output.confirmedBindings == [confirmed])
        #expect(output.candidates.isEmpty)
        #expect(output.proposedFetchGroups.isEmpty)
        let conflict = try #require(output.conflicts.first)
        #expect(conflict.kind == .confirmedBindingDisagreement)
        #expect(conflict.alternatives.map(\.repositoryURL) == ["https://github.com/other/repo"])
    }

    @Test func canonicalizesOnlyGitHubRootAndGroupsCompatibleCandidates() throws {
        let first = fixedID("00000000-0000-0000-0000-000000000001")
        let second = fixedID("00000000-0000-0000-0000-000000000002")
        let output = SourceEvidenceResolver.resolve(
            artifacts: [record(first), record(second)],
            confirmed: [],
            observations: [
                observation(second, url: "HTTPS://GITHUB.COM/Owner/MyRepo.git", path: "skills/Second"),
                observation(first, url: "https://github.com/Owner/MyRepo", path: "skills/First"),
            ]
        )

        #expect(output.candidates.map(\.artifactID) == [first, second])
        let group = try #require(output.proposedFetchGroups.first)
        #expect(output.proposedFetchGroups.count == 1)
        #expect(group.repositoryURL == "https://github.com/owner/myrepo")
        #expect(group.artifactPaths.map(\.artifactID) == [first, second])
        #expect(group.artifactPaths.map(\.packagePath) == ["skills/First", "skills/Second"])
    }

    @Test func competingCandidatesStayOutOfEligibleFetchGroups() throws {
        let id = fixedID("00000000-0000-0000-0000-000000000001")
        let output = SourceEvidenceResolver.resolve(
            artifacts: [record(id)],
            confirmed: [],
            observations: [
                observation(id, url: "https://github.com/Owner/One", path: "skills/one"),
                observation(id, url: "https://github.com/Owner/Two", path: "skills/one"),
            ]
        )

        #expect(output.candidates.isEmpty)
        #expect(output.proposedFetchGroups.isEmpty)
        #expect(output.unresolved == [.init(artifactID: id, reason: .competingObservations)])
        let conflict = try #require(output.conflicts.first)
        #expect(conflict.kind == .competingObservations)
        #expect(conflict.alternatives.map(\.repositoryURL) == [
            "https://github.com/owner/one", "https://github.com/owner/two",
        ])
    }

    @Test func nativeAttachedAndChildArtifactsNeverBecomeStandaloneCandidates() {
        let native = fixedID("00000000-0000-0000-0000-000000000001")
        let attached = fixedID("00000000-0000-0000-0000-000000000002")
        let parent = fixedID("00000000-0000-0000-0000-000000000003")
        let child = fixedID("00000000-0000-0000-0000-000000000004")
        let artifacts = [
            record(native, authority: .nativeOwned),
            record(attached, authority: .attachedAuthoring(sourceRootID: .init())),
            record(parent),
            record(child, parent: parent),
        ]
        let observations = [native, attached, child].map {
            observation($0, url: "https://github.com/Owner/Repo", path: "skills/item")
        }
        let output = SourceEvidenceResolver.resolve(artifacts: artifacts, confirmed: [], observations: observations)

        #expect(output.candidates.isEmpty)
        #expect(output.unresolved.contains(.init(artifactID: native, reason: .ineligibleArtifactAuthority)))
        #expect(output.unresolved.contains(.init(artifactID: attached, reason: .ineligibleArtifactAuthority)))
        #expect(output.unresolved.contains(.init(artifactID: child, reason: .childArtifact)))
    }

    @Test func invalidInputsProduceTypedSanitizedReasons() {
        let locator = fixedID("00000000-0000-0000-0000-000000000001")
        let path = fixedID("00000000-0000-0000-0000-000000000002")
        let ref = fixedID("00000000-0000-0000-0000-000000000003")
        let commit = fixedID("00000000-0000-0000-0000-000000000004")
        let integrity = fixedID("00000000-0000-0000-0000-000000000005")
        let records = [locator, path, ref, commit, integrity].map { record($0) }
        let output = SourceEvidenceResolver.resolve(artifacts: records, confirmed: [], observations: [
            observation(locator, url: "https://github.com/Owner/Repo?token=secret", path: "skills/one"),
            observation(path, url: "https://github.com/Owner/Repo", path: "skills/.git/secret"),
            observation(ref, url: "https://github.com/Owner/Repo", path: "skills/one", ref: "--upload-pack=secret"),
            observation(commit, url: "https://github.com/Owner/Repo", path: "skills/one",
                        commit: .init(kind: .semanticVersion, value: "1.0.0")),
            observation(integrity, url: "https://github.com/Owner/Repo", path: "skills/one",
                        integrity: [.init(algorithm: .vercelProjectSkillFolderSHA256V1, value: "abcd")]),
        ])

        #expect(output.candidates.isEmpty)
        #expect(Set(output.unresolved.map(\.reason)) == [
            .invalidLocator, .invalidPackagePath, .invalidRequestedRef, .invalidObservedCommit, .invalidIntegrity,
        ])
        #expect(output.diagnostics == [.invalidObservation])
    }

    @Test func providerIntegrityAlgorithmsRemainDistinct() throws {
        let github = fixedID("00000000-0000-0000-0000-000000000001")
        let provider = fixedID("00000000-0000-0000-0000-000000000002")
        let tree = String(repeating: "a", count: 40)
        let opaque = String(repeating: "b", count: 40)
        let output = SourceEvidenceResolver.resolve(artifacts: [record(github), record(provider)], confirmed: [], observations: [
            observation(github, url: "https://github.com/Owner/Repo", path: "skills/one",
                        integrity: [.init(algorithm: .githubSkillFolderTreeObjectID, value: tree)]),
            observation(provider, url: "https://github.com/Owner/Repo", path: "skills/two",
                        integrity: [.init(algorithm: .vercelGlobalSkillFolderHashOpaque, value: opaque)]),
        ])

        let values = Dictionary(uniqueKeysWithValues: output.candidates.map { ($0.artifactID, $0.integrity[0].algorithm) })
        #expect(values[github] == .githubSkillFolderTreeObjectID)
        #expect(values[provider] == .vercelGlobalSkillFolderHashOpaque)
    }

    @Test func unsafeLocatorsPathsAndGitRefsCannotEnterFetchProposals() {
        let id = fixedID("00000000-0000-0000-0000-000000000001")
        for url in ["http://github.com/a/b", "https://user:password@github.com/a/b", "https://github.com/a/b/tree/main",
                    "https://github.com/a/%2e%2e", "https://example.test/Owner/Repo"] {
            let output = SourceEvidenceResolver.resolve(artifacts: [record(id)], confirmed: [], observations: [
                observation(id, url: url, path: "skills/x"),
            ])
            #expect(output.proposedFetchGroups.isEmpty)
            #expect(output.unresolved.contains(.init(artifactID: id, reason: .invalidLocator)))
        }
        for path in ["/private/skill", "skills//x", "skills/./x", "skills/../x", "skills\\x", ".GIT/x", "skills/\nx"] {
            let output = SourceEvidenceResolver.resolve(artifacts: [record(id)], confirmed: [], observations: [
                observation(id, url: "https://github.com/a/b", path: path),
            ])
            #expect(output.proposedFetchGroups.isEmpty)
            #expect(output.unresolved.contains(.init(artifactID: id, reason: .invalidPackagePath)))
        }
        for ref in [".", "main.", "feature/.hidden", "refs/foo.lock/main", "-foo", "main\n"] {
            let output = SourceEvidenceResolver.resolve(artifacts: [record(id)], confirmed: [], observations: [
                observation(id, url: "https://github.com/a/b", path: "skills/x", ref: ref),
            ])
            #expect(output.proposedFetchGroups.isEmpty)
            #expect(output.unresolved.contains(.init(artifactID: id, reason: .invalidRequestedRef)))
        }
    }

    @Test func duplicateIdentitiesAndBindingsAreRejectedWithoutFirstWins() {
        let id = fixedID("00000000-0000-0000-0000-000000000001")
        let binding = ConfirmedSourceBinding(
            artifactID: id, repositoryURL: "https://github.com/Owner/Repo",
            requestedRef: "main", packagePath: "skills/one"
        )
        let output = SourceEvidenceResolver.resolve(
            artifacts: [record(id, name: "one"), record(id, name: "other")],
            confirmed: [binding, binding],
            observations: [observation(id, url: "https://github.com/Owner/Repo", path: "skills/one")]
        )

        #expect(output.confirmedBindings.isEmpty)
        #expect(output.candidates.isEmpty)
        #expect(Set(output.conflicts.map(\.kind)) == [.duplicateArtifactIdentity, .duplicateConfirmedBinding])
        #expect(Set(output.unresolved.map(\.reason)) == [.duplicateArtifactIdentity, .duplicateConfirmedBinding])
    }

    @Test func invalidConfirmedIntentSuppressesObservedReplacement() {
        let id = fixedID("00000000-0000-0000-0000-000000000001")
        let invalid = ConfirmedSourceBinding(
            artifactID: id, repositoryURL: "https://github.com/Owner/Repo?token=secret",
            requestedRef: "main", packagePath: "skills/one"
        )
        let output = SourceEvidenceResolver.resolve(
            artifacts: [record(id)], confirmed: [invalid],
            observations: [observation(id, url: "https://github.com/Owner/Replacement", path: "skills/one")]
        )
        #expect(output.confirmedBindings.isEmpty)
        #expect(output.candidates.isEmpty)
        #expect(output.proposedFetchGroups.isEmpty)
        #expect(output.unresolved.contains(.init(artifactID: id, reason: .invalidConfirmedBinding)))
    }

    @Test func upstreamWithoutConfirmedBindingAndUnsupportedKindsStayUnresolved() {
        let upstream = fixedID("00000000-0000-0000-0000-000000000001")
        let mcp = fixedID("00000000-0000-0000-0000-000000000002")
        let output = SourceEvidenceResolver.resolve(
            artifacts: [
                record(upstream, authority: .centralUpstream(subscriptionID: .init())),
                .init(identity: .init(id: mcp, kind: .mcpServer, displayName: "server"), authority: .trackedOnly),
            ],
            confirmed: [],
            observations: [
                observation(upstream, url: "https://github.com/Owner/Repo", path: "skills/one"),
                observation(mcp, url: "https://github.com/Owner/Repo", path: "servers/mcp"),
            ]
        )
        #expect(output.candidates.isEmpty)
        #expect(output.unresolved.contains(.init(artifactID: upstream, reason: .missingConfirmedUpstreamBinding)))
        #expect(output.unresolved.contains(.init(artifactID: mcp, reason: .unsupportedArtifactKind)))
    }

    @Test func differingFactsForOneLocatorAreASeparateReviewConflict() throws {
        let id = fixedID("00000000-0000-0000-0000-000000000001")
        let firstCommit = SourceRevision(kind: .gitCommitSHA1, value: String(repeating: "a", count: 40))
        let secondCommit = SourceRevision(kind: .gitCommitSHA1, value: String(repeating: "b", count: 40))
        let output = SourceEvidenceResolver.resolve(artifacts: [record(id)], confirmed: [], observations: [
            observation(id, url: "https://github.com/Owner/Repo", path: "skills/one", commit: firstCommit),
            observation(id, url: "https://github.com/Owner/Repo", path: "skills/one", commit: secondCommit),
        ])
        #expect(output.candidates.isEmpty)
        #expect(output.proposedFetchGroups.isEmpty)
        #expect(output.unresolved == [.init(artifactID: id, reason: .competingEvidenceFacts)])
        #expect(try #require(output.conflicts.first).kind == .competingEvidenceFacts)
        #expect(try #require(output.conflicts.first).alternatives.count == 2)
    }

    @Test func shuffledInputProducesIdenticalResolution() {
        let first = fixedID("00000000-0000-0000-0000-000000000001")
        let second = fixedID("00000000-0000-0000-0000-000000000002")
        let records = [record(first), record(second)]
        let observations = [
            observation(first, url: "https://github.com/Owner/Repo", path: "skills/one"),
            observation(second, url: "https://github.com/Owner/Repo", path: "skills/two"),
        ]
        let forward = SourceEvidenceResolver.resolve(artifacts: records, confirmed: [], observations: observations)
        let reversed = SourceEvidenceResolver.resolve(
            artifacts: Array(records.reversed()), confirmed: [], observations: Array(observations.reversed()))
        #expect(forward == reversed)
    }

    @Test func opaqueIntegrityDelimitersCannotMakeReviewOrderingAmbiguous() throws {
        let id = fixedID("00000000-0000-0000-0000-000000000001")
        let one: [SourceLockIntegrityEvidence] = [
            .init(algorithm: .vercelGlobalSkillFolderHashOpaque, value: "x|vercelWellKnownOpaque:y"),
        ]
        let two: [SourceLockIntegrityEvidence] = [
            .init(algorithm: .vercelGlobalSkillFolderHashOpaque, value: "x"),
            .init(algorithm: .vercelWellKnownOpaque, value: "y"),
        ]
        let observations = [
            observation(id, url: "https://github.com/owner/repo", path: "skills/one", integrity: one),
            observation(id, url: "https://github.com/owner/repo", path: "skills/one", integrity: two),
        ]
        let forward = SourceEvidenceResolver.resolve(artifacts: [record(id)], confirmed: [], observations: observations)
        let reverse = SourceEvidenceResolver.resolve(artifacts: [record(id)], confirmed: [], observations: Array(observations.reversed()))
        #expect(forward == reverse)
        #expect(try #require(forward.conflicts.first?.alternatives.first).integrity == two)
    }

    @Test func weakContextsAndEvidenceGapsRemainUnresolved() {
        let nameOnly = fixedID("00000000-0000-0000-0000-000000000001")
        let gap = fixedID("00000000-0000-0000-0000-000000000002")
        var gapEvidence = evidence(url: "https://github.com/Owner/Repo", path: "skills/two")
        gapEvidence.gaps = [.missingRequestedRef]
        let output = SourceEvidenceResolver.resolve(artifacts: [record(nameOnly), record(gap)], confirmed: [], observations: [
            .init(artifactID: nameOnly, context: .nameOnly,
                  evidence: evidence(url: "https://github.com/Owner/Repo", path: "skills/one")),
            .init(artifactID: gap, context: .exactRelativePath, evidence: gapEvidence),
        ])
        #expect(Set(output.unresolved.map(\.reason)) == [.insufficientMatchContext, .evidenceGap])
    }

    private func record(
        _ id: ArtifactID, name: String = "skill", authority: ContentAuthority = .trackedOnly,
        parent: ArtifactID? = nil
    ) -> ArtifactRecord {
        .init(identity: .init(id: id, kind: .skill, displayName: name, parentPackageID: parent), authority: authority)
    }

    private func observation(
        _ id: ArtifactID, url: String, path: String, ref: String = "main",
        commit: SourceRevision? = nil, integrity: [SourceLockIntegrityEvidence] = []
    ) -> SourceEvidenceObservation {
        .init(
            artifactID: id, context: .exactRelativePath,
            evidence: evidence(url: url, path: path, ref: ref, integrity: integrity),
            observedCommit: commit
        )
    }

    private func evidence(
        url: String, path: String, ref: String = "main", integrity: [SourceLockIntegrityEvidence] = []
    ) -> SourceLockEvidence {
        .init(
            skillNameHint: "display hint",
            locator: .remote(repositoryID: "owner/repo", sourceType: "github", repositoryURL: url, baseURL: nil),
            revision: .requestedRef(ref), skillPath: path, integrity: integrity
        )
    }

    private func fixedID(_ value: String) -> ArtifactID {
        ArtifactID(UUID(uuidString: value)!)
    }
}
