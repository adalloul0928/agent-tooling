import Foundation
import Testing

@testable import AgentToolingCore

/// Finding a skill in a repository when a registry listing names only the
/// repository and the skill.
struct SkillRepositoryLocateTests {
    private let revision = String(repeating: "a", count: 40)

    private func service(_ runner: LocateRunner) -> SkillRepositoryService {
        let cache = FileManager.default.temporaryDirectory.appending(path: "locate-\(UUID().uuidString)")
        return SkillRepositoryService(cacheURL: cache, runner: runner)
    }

    @Test func theFolderNamedForTheSkillOnTheDefaultBranchIsChosen() async throws {
        let runner = LocateRunner(revision: revision, defaultBranch: "trunk", files: [
            "README.md": "",
            "skills/ab-testing/SKILL.md": "---\nname: ab-testing\ndescription: d\n---\n",
            "skills/seo-audit/SKILL.md": "---\nname: seo-audit\ndescription: d\n---\n",
        ])
        let binding = try await service(runner).locate(skillID: "ab-testing", repositoryURL: "https://github.com/acme/marketing")
        #expect(binding.ref == "trunk")
        #expect(binding.subdirectory == "skills/ab-testing")
        #expect(binding.repositoryURL == "https://github.com/acme/marketing")
        // The branch was asked of the remote, and the fetch used it.
        let fetch = await runner.calls.first { $0.contains("fetch") }
        #expect(fetch?.last == "trunk")
    }

    @Test func aSkillNamedOnlyInItsFrontmatterIsStillFound() async throws {
        let runner = LocateRunner(revision: revision, defaultBranch: "main", files: [
            "one/SKILL.md": "---\nname: release-readiness\ndescription: d\n---\n",
            "two/SKILL.md": "---\nname: weekly-changelog\ndescription: d\n---\n",
        ])
        let binding = try await service(runner).locate(skillID: "Weekly_Changelog", repositoryURL: "https://github.com/acme/tools")
        #expect(binding.subdirectory == "two")
    }

    @Test func theShallowestOfSeveralSameNamedFoldersWins() async throws {
        let runner = LocateRunner(revision: revision, defaultBranch: "main", files: [
            "vendor/deep/ab-testing/SKILL.md": "---\nname: x\ndescription: d\n---\n",
            "ab-testing/SKILL.md": "---\nname: y\ndescription: d\n---\n",
        ])
        let binding = try await service(runner).locate(skillID: "ab-testing", repositoryURL: "https://github.com/acme/tools")
        #expect(binding.subdirectory == "ab-testing")
    }

    @Test func aSkillTheRepositoryDoesNotHoldIsRefusedAndNoRemoteSilenceIsGuessed() async throws {
        let runner = LocateRunner(revision: revision, defaultBranch: nil, files: [
            "skills/other/SKILL.md": "---\nname: other\ndescription: d\n---\n",
        ])
        await #expect(throws: SkillRepositoryError.sourceMissing) {
            try await service(runner).locate(skillID: "ab-testing", repositoryURL: "https://github.com/acme/tools")
        }
        // With no symref answer the fetch fell back to HEAD rather than inventing a branch.
        let fetch = await runner.calls.first { $0.contains("fetch") }
        #expect(fetch?.last == "HEAD")
    }

    @Test func onlyGitHubOverHTTPSIsLookedAt() async throws {
        let runner = LocateRunner(revision: revision, defaultBranch: "main", files: [:])
        await #expect(throws: SkillRepositoryError.invalidRepository) {
            try await service(runner).locate(skillID: "x", repositoryURL: "ssh://git@github.com/acme/tools")
        }
        #expect(await runner.calls.isEmpty)
    }
}

/// Answers the git calls `locate` makes: `ls-remote --symref`, a shallow
/// fetch, `rev-parse`, a name-only `ls-tree`, and `show` of one file.
private actor LocateRunner: CommandRunning {
    let revision: String
    let defaultBranch: String?
    let files: [String: String]
    private(set) var calls: [[String]] = []

    init(revision: String, defaultBranch: String?, files: [String: String]) {
        self.revision = revision
        self.defaultBranch = defaultBranch
        self.files = files
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        guard executable == "/usr/bin/env" else { return failure() }
        calls.append(arguments)
        if arguments.contains("ls-remote") {
            guard let defaultBranch else { return success("\(revision)\tHEAD\n") }
            return success("ref: refs/heads/\(defaultBranch)\tHEAD\n\(revision)\tHEAD\n")
        }
        if arguments.contains("init"), arguments.contains("--bare"), let path = arguments.last {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            return success()
        }
        if arguments.contains("fetch") { return success() }
        if arguments.contains("rev-parse") { return success(revision + "\n") }
        if arguments.contains("ls-tree") {
            return success(files.keys.sorted().map { $0 + "\0" }.joined())
        }
        if arguments.contains("show"), let spec = arguments.last, let colon = spec.firstIndex(of: ":") {
            let path = String(spec[spec.index(after: colon)...])
            guard let content = files[path] else { return failure() }
            return success(content)
        }
        return failure()
    }

    private func success(_ output: String = "") -> CommandOutput { .init(status: 0, standardOutput: output, standardError: "") }
    private func failure() -> CommandOutput { .init(status: 1, standardOutput: "", standardError: "rejected") }
}
