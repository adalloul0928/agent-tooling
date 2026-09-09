import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceSkillPreparationTests {
    @Test func personalPreparationPreservesCompleteTreeAndReviewFacts() async throws {
        let root = temporaryDirectory("personal")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        let definition = root.appending(path: "SKILL.md")
        try markdown.write(to: definition, atomically: true, encoding: .utf8)
        let script = root.appending(path: "scripts/run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data([0, 255, 4]).write(to: root.appending(path: "asset.bin"))

        let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: root)

        #expect(prepared.frontmatter.name == "review")
        #expect(prepared.tree.entries.contains { $0.relativePath == "scripts/run.sh" })
        #expect(prepared.tree.entries.contains { $0.relativePath == "asset.bin" })
        #expect(prepared.review.contentDigest == prepared.tree.digest)
        #expect(prepared.review.excludedRootGitMetadata)
        #expect(prepared.review.upstream == nil)
        #expect(try String(contentsOf: definition, encoding: .utf8) == markdown)
    }

    @Test func personalPreparationRequiresRegularUTF8RootSkillDefinition() throws {
        let missing = try CapturedPackageTree(entries: [
            .init(relativePath: "notes.md", kind: .file(bytes: Data(), executable: false)),
        ])
        #expect(throws: WorkspaceSkillPreparationError.missingSkillDefinition) {
            try WorkspaceSkillPreparation.personal(tree: missing)
        }

        let invalidUTF8 = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data([0xff]), executable: false)),
        ])
        #expect(throws: WorkspaceSkillPreparationError.invalidSkillDefinition) {
            try WorkspaceSkillPreparation.personal(tree: invalidUTF8)
        }

        let directory = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .directory),
        ])
        #expect(throws: WorkspaceSkillPreparationError.missingSkillDefinition) {
            try WorkspaceSkillPreparation.personal(tree: directory)
        }
    }

    @Test func pluginRootsCannotMasqueradeAsStandaloneSkills() throws {
        for markerEntries in [
            [PackageTreeEntry(relativePath: "plugin.json", kind: .file(bytes: Data("{}".utf8), executable: false))],
            [PackageTreeEntry(relativePath: "PLUGIN.JSON", kind: .file(bytes: Data("{}".utf8), executable: false))],
            [PackageTreeEntry(relativePath: "agent-plugin.json", kind: .file(bytes: Data("{}".utf8), executable: false))],
            [
                PackageTreeEntry(relativePath: ".claude-plugin", kind: .directory),
                PackageTreeEntry(relativePath: ".claude-plugin/plugin.json", kind: .file(bytes: Data("{}".utf8), executable: false)),
            ],
            [
                PackageTreeEntry(relativePath: ".codex-plugin", kind: .directory),
                PackageTreeEntry(relativePath: ".codex-plugin/plugin.json", kind: .file(bytes: Data("{}".utf8), executable: false)),
            ],
            [
                PackageTreeEntry(relativePath: ".agents", kind: .directory),
                PackageTreeEntry(relativePath: ".agents/plugin.json", kind: .file(bytes: Data("{}".utf8), executable: false)),
            ],
        ] {
            let tree = try CapturedPackageTree(entries: [skillEntry] + markerEntries)
            #expect(throws: WorkspaceSkillPreparationError.pluginPackageRoot) {
                try WorkspaceSkillPreparation.personal(tree: tree)
            }
        }
    }

    @Test func upstreamPreparationUsesFetchedCommitAndCanonicalPublisher() async throws {
        let cache = temporaryDirectory("upstream")
        defer { try? FileManager.default.removeItem(at: cache) }
        let revision = String(repeating: "a", count: 40)
        let runner = PreparationRepositoryRunner(revision: revision, files: [
            "SKILL.md": Data(markdown.utf8),
            "references/guide.md": Data("guide\n".utf8),
        ])
        var binding = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/Example/Skills.git",
            ref: "release/v1",
            subdirectory: "skills/review")
        binding.lastCheckedFingerprint = String(repeating: "b", count: 64)

        let prepared = try await WorkspaceSkillPreparation.fetchUpstream(
            binding: binding, cacheURL: cache, runner: runner)
        let upstream = try #require(prepared.review.upstream)

        #expect(upstream.repositoryURL == "https://github.com/example/skills")
        #expect(upstream.publisherID == "github:example")
        #expect(upstream.requestedRef == "release/v1")
        #expect(upstream.packageRelativePath == "skills/review")
        #expect(upstream.revision == .init(kind: .gitCommitSHA1, value: revision))
        #expect(prepared.review.contentDigest == prepared.tree.digest)
        #expect(prepared.review.contentDigest.value != binding.lastCheckedFingerprint)
        #expect(prepared.tree.entries.map(\.relativePath).contains("references/guide.md"))

        let calls = await runner.calls
        #expect(calls.contains { $0.contains("--depth=1") && $0.contains("--no-recurse-submodules") })
        #expect(calls.allSatisfy { $0.contains("GIT_TERMINAL_PROMPT=0") })
        let taskRoot = cache.appending(path: "skill-repositories")
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: taskRoot.path)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func upstreamRootPathIsDotAndSHA256RevisionStaysTyped() async throws {
        let cache = temporaryDirectory("upstream-root")
        defer { try? FileManager.default.removeItem(at: cache) }
        let revision = String(repeating: "c", count: 64)
        let runner = PreparationRepositoryRunner(revision: revision, files: ["SKILL.md": Data(markdown.utf8)])
        let binding = try SkillRepositoryBinding(repositoryURL: "https://github.com/owner/repository")

        let prepared = try await WorkspaceSkillPreparation.fetchUpstream(
            binding: binding, cacheURL: cache, runner: runner)

        #expect(prepared.review.upstream?.packageRelativePath == ".")
        #expect(prepared.review.upstream?.revision == .init(kind: .gitCommitSHA256, value: revision))
    }

    @Test func repositoryCancellationPropagatesAndDiscardsTemporaryCheckout() async throws {
        let cache = temporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: cache) }
        let runner = PreparationRepositoryRunner(
            revision: String(repeating: "a", count: 40), files: [:], cancelOnFetch: true)
        let binding = try SkillRepositoryBinding(repositoryURL: "https://github.com/example/skills")

        await #expect(throws: CancellationError.self) {
            try await WorkspaceSkillPreparation.fetchUpstream(binding: binding, cacheURL: cache, runner: runner)
        }
        let taskRoot = cache.appending(path: "skill-repositories")
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: taskRoot.path)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func invalidFrontmatterAndLinkedRootDefinitionRemainUnmodified() throws {
        let invalid = Data("---\nname: incomplete\n---\nKeep these bytes.\n".utf8)
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "SKILL.md", kind: .file(bytes: invalid, executable: false)),
        ])
        #expect(throws: WorkspaceSkillPreparationError.invalidSkillDefinition) {
            try WorkspaceSkillPreparation.personal(tree: tree)
        }
        #expect(tree.entries[0].kind == .file(bytes: invalid, executable: false))
        let linked = try CapturedPackageTree(entries: [
            .init(relativePath: "definition.md", kind: .file(bytes: Data(markdown.utf8), executable: false)),
            .init(relativePath: "SKILL.md", kind: .symbolicLink(target: "definition.md")),
        ])
        #expect(throws: WorkspaceSkillPreparationError.missingSkillDefinition) {
            try WorkspaceSkillPreparation.personal(tree: linked)
        }
    }

    private var markdown: String {
        "---\nname: review\ndescription: Review a document\n---\n# Instructions\n"
    }

    private var skillEntry: PackageTreeEntry {
        .init(relativePath: "SKILL.md", kind: .file(bytes: Data(markdown.utf8), executable: false))
    }

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "workspace-skill-preparation-\(label)-\(UUID().uuidString)")
    }
}

private actor PreparationRepositoryRunner: CommandRunning {
    let revision: String
    let files: [String: Data]
    let cancelOnFetch: Bool
    private(set) var calls: [[String]] = []

    init(revision: String, files: [String: Data], cancelOnFetch: Bool = false) {
        self.revision = revision
        self.files = files
        self.cancelOnFetch = cancelOnFetch
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        guard executable == "/usr/bin/env", let currentDirectory else {
            return .init(status: 1, standardOutput: "", standardError: "")
        }
        calls.append(arguments)
        if arguments.contains("init"), arguments.contains("--bare") {
            guard let path = arguments.last else { return failure() }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            return success()
        }
        if arguments.contains("fetch") {
            if cancelOnFetch { throw CancellationError() }
            return success()
        }
        if arguments.contains("rev-parse") {
            return success(revision + "\n")
        }
        if arguments.contains("ls-tree") {
            let selected = arguments.last ?? "."
            let prefix = selected == "." ? "" : selected + "/"
            let listing = files.keys.sorted().map { path in
                let bytes = files[path]?.count ?? 0
                return "100644 blob abc \(bytes)\t\(prefix)\(path)\0"
            }.joined()
            return success(listing)
        }
        if arguments.contains("checkout") {
            guard let worktree = arguments.first(where: { $0.hasPrefix("--work-tree=") }) else {
                return failure()
            }
            let export = URL(fileURLWithPath: String(worktree.dropFirst("--work-tree=".count)))
            let selected = arguments.last ?? "."
            let root = selected == "." ? export : export.appending(path: selected)
            for (path, bytes) in files {
                let destination = root.appending(path: path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination)
            }
            return success()
        }
        _ = currentDirectory
        return failure()
    }

    private func success(_ output: String = "") -> CommandOutput {
        .init(status: 0, standardOutput: output, standardError: "")
    }

    private func failure() -> CommandOutput {
        .init(status: 1, standardOutput: "", standardError: "fixture command rejected")
    }
}
