import Foundation
import Testing

@testable import AgentToolingCore

struct VercelSkillLockReaderTests {
    @Test func globalV3ProducesTypedTreeEvidenceAndUsesXDGLocation() throws {
        let context = try VercelSkillLockReader.globalContext(
            homeDirectory: "/Users/example", xdgStateHome: "/tmp/state")
        #expect(context.lockFilePath == "/tmp/state/skills/.skill-lock.json")
        let bytes = Data("""
        {
          "version": 3,
          "skills": {
            "review": {
              "source": "vercel-labs/skills",
              "sourceType": "github",
              "sourceUrl": "https://github.com/vercel-labs/skills",
              "ref": "main",
              "skillPath": "skills/review/SKILL.md",
              "skillFolderHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "installedAt": "2026-09-01T00:00:00.000Z",
              "updatedAt": "2026-09-02T00:00:00.000Z",
              "pluginName": "review-tools",
              "wellKnownDigest": "sha256:opaque-provider-value",
              "futureField": {"retainedByVercel": true}
            }
          }
        }
        """.utf8)

        let result = VercelSkillLockReader.read(bytes: bytes, context: context)
        #expect(result.status == .recognized)
        #expect(result.schemaVersion == 3)
        #expect(result.evidence.count == 1)
        #expect(result.evidence[0].skillNameHint == "review")
        #expect(result.evidence[0].revision == .requestedRef("main"))
        #expect(result.evidence[0].skillPath == "skills/review/SKILL.md")
        #expect(result.evidence[0].integrity.map(\.algorithm) == [
            .githubSkillFolderTreeObjectID, .vercelWellKnownOpaque,
        ])
        #expect(result.evidence[0].gaps.isEmpty)
    }

    @Test func globalFallbackAndProjectLocationsAreExplicitDeviceContext() throws {
        let global = try VercelSkillLockReader.globalContext(homeDirectory: "/Users/example")
        let emptyXDG = try VercelSkillLockReader.globalContext(
            homeDirectory: "/Users/example", xdgStateHome: "")
        let project = try VercelSkillLockReader.projectContext(projectRoot: "/tmp/project")
        #expect(global.lockFilePath == "/Users/example/.agents/.skill-lock.json")
        #expect(emptyXDG == global)
        #expect(project.lockFilePath == "/tmp/project/skills-lock.json")
        #expect(throws: WorkspaceDomainValidationError.self) {
            _ = try VercelSkillLockReader.globalContext(
                homeDirectory: "/Users/example", xdgStateHome: "relative/state")
        }
    }

    @Test func projectV1KeepsComputedDigestDistinctAndResolvesLocalPathOnlyOnDevice() throws {
        let context = try VercelSkillLockReader.projectContext(projectRoot: "/tmp/project")
        let bytes = Data("""
        {
          "version": 1,
          "skills": {
            "remote": {
              "source": "owner/repo",
              "sourceUrl": "https://github.com/owner/repo",
              "ref": "v1.2.3",
              "sourceType": "github",
              "skillPath": "skills/remote/SKILL.md",
              "computedHash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            },
            "local": {
              "source": "../shared/local-skill",
              "sourceType": "local",
              "computedHash": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            }
          }
        }
        """.utf8)

        let result = VercelSkillLockReader.read(bytes: bytes, context: context)
        #expect(result.evidence.count == 2)
        let local = try #require(result.evidence.first(where: { $0.skillNameHint == "local" }))
        #expect(local.locator == .deviceLocal(
            originalPath: "../shared/local-skill", resolvedPath: "/tmp/shared/local-skill"))
        #expect(local.gaps.contains(.deviceLocalOnly))
        let remote = try #require(result.evidence.first(where: { $0.skillNameHint == "remote" }))
        #expect(remote.integrity == [.init(
            algorithm: .vercelProjectSkillFolderSHA256V1,
            value: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")])
        #expect(remote.revision == .requestedRef("v1.2.3"))
    }

    @Test func unsupportedVersionsRemainExplicitWithoutBestEffortEntries() throws {
        let global = try VercelSkillLockReader.globalContext(homeDirectory: "/Users/example")
        for version in [2, 4] {
            let bytes = Data("{\"version\":\(version),\"skills\":{\"same\":{}}}".utf8)
            let result = VercelSkillLockReader.read(bytes: bytes, context: global)
            #expect(result.status == .unsupportedVersion)
            #expect(result.schemaVersion == version)
            #expect(result.evidence.isEmpty)
            #expect(result.diagnostics.map(\.code) == [.unsupportedVersion])
        }
        let project = try VercelSkillLockReader.projectContext(projectRoot: "/tmp/project")
        let projectResult = VercelSkillLockReader.read(
            bytes: Data("{\"version\":2,\"skills\":{}}".utf8), context: project)
        #expect(projectResult.status == .unsupportedVersion)
        #expect(projectResult.schemaVersion == 2)
    }

    @Test func malformedAndOversizedDocumentsAreBounded() throws {
        let context = try VercelSkillLockReader.globalContext(homeDirectory: "/Users/example")
        let malformed = VercelSkillLockReader.read(bytes: Data("{".utf8), context: context)
        let wrongRoot = VercelSkillLockReader.read(bytes: Data("[]".utf8), context: context)
        let wrongSkills = VercelSkillLockReader.read(
            bytes: Data("{\"version\":3,\"skills\":[]}".utf8), context: context)
        let oversized = VercelSkillLockReader.read(
            bytes: Data(repeating: 0x20, count: VercelSkillLockReader.maximumBytes + 1), context: context)

        #expect(malformed.status == .malformed)
        #expect(malformed.diagnostics.map(\.code) == [.malformedJSON])
        #expect(wrongRoot.diagnostics.map(\.code) == [.invalidRoot])
        #expect(wrongSkills.diagnostics.map(\.code) == [.invalidSkillsMap])
        #expect(oversized.diagnostics.map(\.code) == [.documentTooLarge])
    }

    @Test func incompleteAndInvalidFieldsProduceBoundedEvidenceAndDiagnostics() throws {
        let project = try VercelSkillLockReader.projectContext(projectRoot: "/tmp/project")
        let bytes = Data("""
        {
          "version": 1,
          "skills": {
            "bad": {
              "source": "owner/repo",
              "sourceType": "github",
              "skillPath": "../escape/SKILL.md",
              "computedHash": "NOT-A-DIGEST"
            },
            "good": {
              "source": "owner/other",
              "sourceUrl": "https://github.com/owner/other",
              "ref": "main",
              "sourceType": "github",
              "skillPath": "skills/good/SKILL.md",
              "computedHash": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
            },
            "wrong-shape": true
          }
        }
        """.utf8)

        let result = VercelSkillLockReader.read(bytes: bytes, context: project)
        #expect(result.status == .recognized)
        #expect(result.evidence.map(\.skillNameHint) == ["bad", "good"])
        let bad = result.evidence[0]
        #expect(bad.skillPath == nil)
        #expect(bad.gaps.contains(.missingRequestedRef))
        #expect(bad.gaps.contains(.invalidSkillPath))
        #expect(bad.gaps.contains(.invalidIntegrity))
        #expect(result.diagnostics.contains(where: { $0.code == .invalidEntry }))
    }

    @Test func credentialBearingLocatorIsRedactedFromEvidenceAndDiagnostics() throws {
        let global = try VercelSkillLockReader.globalContext(homeDirectory: "/Users/example")
        let secret = "never-serialize-this-secret"
        let bytes = Data("""
        {"version":3,"skills":{"private":{"source":"https://example.com/repo?token=\(secret)","sourceType":"github","sourceUrl":"https://user:\(secret)@example.com/repo","sourceBaseUrl":"https://example.com/base#\(secret)","ref":"main","skillPath":"skills/private/SKILL.md","skillFolderHash":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","installedAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z"}}}
        """.utf8)
        let result = VercelSkillLockReader.read(bytes: bytes, context: global)
        let encodedResult = try JSONEncoder().encode(result)

        #expect(result.evidence[0].locator == .unavailable(sourceType: "github"))
        #expect(String(decoding: encodedResult, as: UTF8.self).contains(secret) == false)
    }

    @Test func nonGitHubGlobalHashRemainsProviderOpaque() throws {
        let context = try VercelSkillLockReader.globalContext(homeDirectory: "/Users/example")
        let bytes = Data("""
        {"version":3,"skills":{"docs":{"source":"mintlify/docs","sourceType":"mintlify","sourceUrl":"https://mintlify.com/docs","ref":"main","skillPath":"skills/docs/SKILL.md","skillFolderHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","installedAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z"}}}
        """.utf8)
        let result = VercelSkillLockReader.read(bytes: bytes, context: context)

        #expect(result.evidence[0].integrity.map(\.algorithm) == [.vercelGlobalSkillFolderHashOpaque])
    }

    @Test func callerConstructedContextIsValidatedBeforeParsing() {
        let bytes = Data("{\"version\":3,\"skills\":{}}".utf8)
        let relative = VercelSkillLockReader.read(
            bytes: bytes, context: .global(lockFilePath: "relative/.skill-lock.json"))
        let mismatchedProject = VercelSkillLockReader.read(
            bytes: bytes,
            context: .project(lockFilePath: "/tmp/other/skills-lock.json", projectRoot: "/tmp/project"))

        #expect(relative.status == .malformed)
        #expect(relative.diagnostics.map(\.code) == [.invalidContext])
        #expect(mismatchedProject.diagnostics.map(\.code) == [.invalidContext])
    }

    @Test func equalSkillNamesAcrossScopesStaySeparateNameOnlyEvidence() throws {
        let global = try VercelSkillLockReader.globalContext(homeDirectory: "/Users/example")
        let project = try VercelSkillLockReader.projectContext(projectRoot: "/tmp/project")
        let globalBytes = Data("""
        {"version":3,"skills":{"same":{"source":"one/repo","sourceType":"github","sourceUrl":"https://github.com/one/repo","ref":"main","skillPath":"skills/same/SKILL.md","skillFolderHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","installedAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z"}}}
        """.utf8)
        let projectBytes = Data("""
        {"version":1,"skills":{"same":{"source":"two/repo","sourceType":"github","sourceUrl":"https://github.com/two/repo","ref":"main","skillPath":"skills/same/SKILL.md","computedHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}
        """.utf8)
        let globalResult = VercelSkillLockReader.read(bytes: globalBytes, context: global)
        let projectResult = VercelSkillLockReader.read(bytes: projectBytes, context: project)

        #expect(globalResult.evidence[0].skillNameHint == projectResult.evidence[0].skillNameHint)
        #expect(globalResult.evidence[0].locator != projectResult.evidence[0].locator)
    }
}
