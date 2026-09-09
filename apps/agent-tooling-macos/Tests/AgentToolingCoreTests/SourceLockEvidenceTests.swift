import Foundation
import Testing

@testable import AgentToolingCore

struct SourceLockEvidenceTests {
    @Test func evidenceDoesNotClaimWorkspaceIdentityAuthorityOrApprovedRevision() {
        let evidence = SourceLockEvidence(
            skillNameHint: "same-name",
            locator: .remote(
                repositoryID: "owner/repo", sourceType: "github",
                repositoryURL: "https://github.com/owner/repo", baseURL: nil),
            revision: .requestedRef("main"),
            skillPath: "skills/same-name/SKILL.md",
            integrity: [.init(
                algorithm: .githubSkillFolderTreeObjectID,
                value: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")])

        #expect(evidence.skillNameHint == "same-name")
        #expect(evidence.revision == .requestedRef("main"))
        #expect(evidence.integrity[0].algorithm != .vercelProjectSkillFolderSHA256V1)
    }
}
