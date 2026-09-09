import Foundation
import Testing

@testable import AgentToolingCore

struct GitCheckoutSourceReaderTests {
    @Test func realCheckoutUsesTrackedBranchAndExactFolderWithoutChangingGitFiles() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        try await fixture.git(["config", "remote.publisher.url", "git@github.com:Example/Skill-Library.git"])
        try await fixture.git(["config", "branch.work.remote", "publisher"])
        try await fixture.git(["config", "branch.work.merge", "refs/heads/main"])
        let before = try fixture.gitFiles()
        let id = ArtifactID()
        let recognition = try await GitCheckoutSourceReader().recognize(artifactID: id, directory: fixture.skill)
        #expect(recognition.issues.isEmpty)
        #expect(recognition.checkout.branch == "work")
        #expect(recognition.checkout.upstream?.requestedRef == "main")
        #expect(recognition.checkout.upstream?.repositoryURL == "https://github.com/example/skill-library")
        #expect(recognition.checkout.headCommit?.kind == .gitCommitSHA1)
        #expect(!recognition.checkout.isLinkedWorktree)
        #expect(try fixture.gitFiles() == before)

        let artifact = ArtifactRecord(identity: .init(id: id, kind: .skill, displayName: "A display name"), authority: .trackedOnly)
        let result = SourceEvidenceResolver.resolve(artifacts: [artifact], confirmed: [], observations: recognition.observations)
        let candidate = try #require(result.candidates.first)
        #expect(candidate.artifactID == id)
        #expect(candidate.packagePath == "skills/one")
        #expect(candidate.requestedRef == "main")
        #expect(candidate.observedCommit == recognition.checkout.headCommit)
        #expect(candidate.integrity.isEmpty) // A Git commit is not a content digest.
    }

    @Test func realLinkedWorktreeIsDistinctAndDetachedHEADDoesNotInventSourceRef() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let linked = fixture.container.appendingPathComponent("linked")
        try await fixture.git(["worktree", "add", "--detach", linked.path, "HEAD"])
        let main = try await GitCheckoutSourceReader().capture(directory: fixture.root)
        let other = try await GitCheckoutSourceReader().recognize(artifactID: .init(), directory: linked)
        #expect(other.checkout.isLinkedWorktree)
        #expect(other.checkout.commonGitDirectory == main.commonGitDirectory)
        #expect(other.checkout.gitDirectory != main.gitDirectory)
        #expect(other.checkout.headCommit == main.headCommit)
        #expect(other.checkout.branch == nil)
        #expect(other.checkout.diagnostics.contains(.detachedHEAD))
        #expect(other.observations.isEmpty)
        #expect(other.issues == [.noUpstream])
    }

    @Test func realUnbornCheckoutAndMissingTrackingStayUnresolved() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        try await fixture.initialize(commit: false)
        try await fixture.git(["config", "remote.origin.url", "https://github.com/example/library"])
        let result = try await GitCheckoutSourceReader().recognize(artifactID: .init(), directory: fixture.skill)
        #expect(result.checkout.headCommit == nil)
        #expect(result.checkout.diagnostics.contains(.unbornHEAD))
        #expect(result.checkout.diagnostics.contains(.missingUpstream))
        #expect(result.observations.isEmpty)
        #expect(result.issues == [.noUpstream, .noCommit])
    }

    @Test func realWorktreeConfigIsReadAndIncludedConfigRemainsExplicitlyIncomplete() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        try await fixture.git(["config", "extensions.worktreeConfig", "true"])
        try await fixture.git(["config", "--worktree", "remote.publisher.url", "https://github.com/example/library"])
        try await fixture.git(["config", "--worktree", "branch.work.remote", "publisher"])
        try await fixture.git(["config", "--worktree", "branch.work.merge", "refs/heads/main"])
        let reader = GitCheckoutSourceReader()
        #expect(try await reader.recognize(artifactID: .init(), directory: fixture.skill).observations.count == 1)
        let omitted = fixture.container.appendingPathComponent("omitted-config")
        try "[remote \"private\"]\nurl = https://user:private-token@github.com/example/private\n".write(to: omitted, atomically: true, encoding: .utf8)
        try await fixture.git(["config", "include.path", omitted.path])
        let result = try await reader.recognize(artifactID: .init(), directory: fixture.skill)
        #expect(result.checkout.diagnostics.contains(.includedConfigurationOmitted))
        #expect(result.checkout.remotes.map(\.name) == ["publisher"])
        #expect(result.observations.isEmpty)
        #expect(result.issues == [.incompleteConfiguration])
        #expect(!String(reflecting: result).contains("private-token"))
    }

    @Test func remoteNormalizationNeverRetainsCredentialValuesOrGuessesOtherHosts() {
        let normalized = "https://github.com/example/library"
        for input in ["https://GitHub.com/Example/Library.git", "git@github.com:Example/Library.git", "ssh://git@github.com/Example/Library.git"] {
            #expect(GitCheckoutSourceReader.canonicalRemoteURL(input) == normalized)
        }
        for input in [
            "https://user:secret@github.com/example/library", "https://github.com/example/library?token=secret",
            "ssh://secret@github.com/example/library", "ssh://git:secret@github.com/example/library",
            "ssh://git@github.com:2222/example/library", "git@github-alias:example/library",
            "git@github.com:/example/library", "https://github.com/example/library/tree/main",
            "https://gitlab.com/example/library", "/a/local/repository", "ext::evil command",
            "https://github.com/example/%6cibrary", "https://github.com/example/library\nsecret",
        ] {
            #expect(GitCheckoutSourceReader.canonicalRemoteURL(input) == nil)
        }
    }

    @Test func unsafeAndCompetingRemotesAreSanitizedAndNeverChooseFirst() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        let config = "remote.origin.url\nhttps://user:secret@github.com/example/library\0"
            + "remote.origin.url\nhttps://github.com/example/other\0"
            + "branch.work.remote\norigin\0branch.work.merge\nrefs/heads/main\0"
        let runner = CheckoutReaderStub(root: fixture.root, config: config)
        let result = try await GitCheckoutSourceReader(runner: runner).recognize(artifactID: .init(), directory: fixture.skill)
        #expect(result.checkout.upstream == nil)
        #expect(result.checkout.diagnostics.contains(.unsupportedRemote))
        #expect(result.checkout.diagnostics.contains(.ambiguousUpstream))
        #expect(result.observations.isEmpty)
        #expect(!String(reflecting: result).contains("secret"))
    }

    @Test func conflictingBranchConfigurationAndLocalRepositoryUpstreamsAreNotRemoteSources() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        for suffix in ["branch.work.remote\nother\0", "branch.work.merge\nrefs/heads/other\0"] {
            let runner = CheckoutReaderStub(root: fixture.root, config: CheckoutReaderStub.validConfig + suffix)
            let result = try await GitCheckoutSourceReader(runner: runner).capture(directory: fixture.skill)
            #expect(result.upstream == nil)
            #expect(result.diagnostics.contains(.ambiguousUpstream))
        }
        let local = "branch.work.remote\n.\0branch.work.merge\nrefs/heads/main\0"
        let runner = CheckoutReaderStub(root: fixture.root, config: local)
        let result = try await GitCheckoutSourceReader(runner: runner).capture(directory: fixture.skill)
        #expect(result.upstream == nil)
        #expect(result.diagnostics.contains(.unsupportedUpstream))
    }

    @Test func changedCommitOrConfigBetweenSnapshotsIsRejected() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        for mode in [CheckoutReaderStub.Mode.changedCommit, .changedConfig] {
            let runner = CheckoutReaderStub(root: fixture.root, mode: mode)
            await #expect(throws: GitCheckoutSourceReadError.changedDuringCapture) {
                try await GitCheckoutSourceReader(runner: runner).capture(directory: fixture.skill)
            }
        }
    }

    @Test func boundsOutputAndRejectsMalformedPathsAndObjectIDs() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        let modes: [(CheckoutReaderStub.Mode, GitCheckoutSourceReadError)] = [
            (.oversized, .outputLimitExceeded), (.relativeRoot, .invalidOutput),
            (.malformedCommit, .invalidOutput), (.malformedConfig, .invalidOutput),
        ]
        for (mode, error) in modes {
            await #expect(throws: error) {
                try await GitCheckoutSourceReader(runner: CheckoutReaderStub(root: fixture.root, mode: mode))
                    .capture(directory: fixture.skill)
            }
        }
    }

    @Test func commandFailureAndCancellationDoNotExposeRunnerDetails() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        await #expect(throws: GitCheckoutSourceReadError.commandFailed) {
            try await GitCheckoutSourceReader(runner: CheckoutReaderStub(root: fixture.root, mode: .failure))
                .capture(directory: fixture.skill)
        }
        await #expect(throws: CancellationError.self) {
            try await GitCheckoutSourceReader(runner: CheckoutReaderStub(root: fixture.root, mode: .cancelled))
                .capture(directory: fixture.skill)
        }
    }

    @Test func metadataPathsCannotBecomePackagesAndCommandsRemainReadOnly() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        let metadata = fixture.root.appendingPathComponent(".git/fake-skill")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let runner = CheckoutReaderStub(root: fixture.root)
        let result = try await GitCheckoutSourceReader(runner: runner).recognize(artifactID: .init(), directory: metadata)
        #expect(result.issues == [.excludedPackagePath])
        #expect(result.observations.isEmpty)
        let calls = await runner.calls
        #expect(calls.count == 10)
        for call in calls {
            #expect(call.executable == "/usr/bin/git")
            #expect(call.arguments.prefix(6) == ["--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"])
            #expect(["rev-parse", "symbolic-ref", "config"].contains(call.arguments[6]))
            if call.arguments[6] == "config" {
                #expect(call.arguments.contains("--no-includes"))
                if call.arguments.contains("--get-regexp") {
                    #expect(call.arguments.contains("--null"))
                } else {
                    #expect(call.arguments.suffix(3) == ["--type=bool", "--get", "extensions.worktreeConfig"])
                }
            }
        }
    }

    @Test func nonRepositoryAndEscapingSymlinkDoNotMatchNearbyCheckout() async throws {
        let fixture = try CheckoutFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let outside = fixture.container.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("skills/escaped")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        await #expect(throws: GitCheckoutSourceReadError.notWorkingTree) {
            try await GitCheckoutSourceReader().recognize(artifactID: .init(), directory: link)
        }
        await #expect(throws: GitCheckoutSourceReadError.invalidDirectory) {
            try await GitCheckoutSourceReader().capture(directory: outside.appendingPathComponent("absent"))
        }
    }
}

private struct CheckoutFixture {
    let container: URL
    var root: URL { container.appendingPathComponent("checkout") }
    var skill: URL { root.appendingPathComponent("skills/one") }

    init() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("checkout-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    func initialize(commit: Bool = true) async throws {
        try await git(["init", "--template=", "--initial-branch=work"])
        if commit {
            try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                           "commit", "--allow-empty", "--no-gpg-sign", "-m", "Fixture"])
        }
    }

    func git(_ arguments: [String]) async throws {
        let output = try await ProcessCommandRunner(timeout: .seconds(10)).run(
            executable: "/usr/bin/git",
            arguments: ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments,
            currentDirectory: root
        )
        #expect(output.status == 0, "Fixture Git command failed: \(output.standardError)")
        guard output.status == 0 else { throw GitCheckoutSourceReadError.commandFailed }
    }

    func gitFiles() throws -> [String: Data] {
        let gitRoot = root.appendingPathComponent(".git")
        let enumerator = try #require(FileManager.default.enumerator(at: gitRoot, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(gitRoot.path.count))] = try Data(contentsOf: file)
            }
        }
        return result
    }

    func remove() { try? FileManager.default.removeItem(at: container) }
}

private actor CheckoutReaderStub: CommandRunning {
    enum Mode { case normal, changedCommit, changedConfig, oversized, relativeRoot, malformedCommit, malformedConfig, failure, cancelled }
    struct Call: Sendable { let executable: String; let arguments: [String] }
    static let validConfig = "remote.origin.url\nhttps://github.com/example/library\0branch.work.remote\norigin\0branch.work.merge\nrefs/heads/main\0"
    let root: URL
    let mode: Mode
    let config: String
    var captures = 0
    var calls: [Call] = []

    init(root: URL, config: String = validConfig, mode: Mode = .normal) {
        self.root = root
        self.mode = mode
        self.config = config
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        calls.append(.init(executable: executable, arguments: arguments))
        if mode == .failure { throw NSError(domain: "private-token-in-runner-message", code: 1) }
        if mode == .cancelled { throw CancellationError() }
        if arguments.contains("--show-toplevel") {
            captures += 1
            if mode == .relativeRoot { return ok("relative\n.git\n.git\n") }
            return ok("\(root.path)\n\(root.path)/.git\n\(root.path)/.git\n")
        }
        if arguments.contains("HEAD^{commit}") {
            if mode == .malformedCommit { return ok("v1.0\n") }
            return ok(String(repeating: mode == .changedCommit && captures > 1 ? "b" : "a", count: 40) + "\n")
        }
        if arguments.contains("symbolic-ref") { return ok("refs/heads/work\n") }
        if arguments.contains("extensions.worktreeConfig") { return .init(status: 1, standardOutput: "", standardError: "") }
        if arguments.contains("config") {
            if mode == .oversized { return ok(String(repeating: "x", count: 65_537)) }
            if mode == .malformedConfig { return ok("remote.origin.url\nunterminated") }
            if mode == .changedConfig && captures > 1 { return ok(config + "include.path\n/new-config\0") }
            return ok(config)
        }
        return .init(status: 1, standardOutput: "", standardError: "")
    }

    private func ok(_ output: String) -> CommandOutput { .init(status: 0, standardOutput: output, standardError: "") }
}
