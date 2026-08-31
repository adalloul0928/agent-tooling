import Foundation
import Testing

@testable import AgentToolingCore

private actor CodexSkillDraftRunnerStub: StandardInputCommandRunning {
    enum Behavior: Sendable {
        case valid(name: String)
        case completeReviewInventory(name: String)
        case hiddenNestedFile(name: String)
        case overDepthFile(name: String)
        case twoSkills
        case symbolicLink
        case failure
        case successWithoutDraft
    }

    struct Invocation: Sendable {
        var executable: String
        var arguments: [String]
        var standardInput: Data
        var currentDirectory: URL?
    }

    private let behavior: Behavior
    private var invocations: [Invocation] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func run(
        executable: String,
        arguments: [String],
        standardInput: Data,
        currentDirectory: URL?
    ) async throws -> CommandOutput {
        invocations.append(
            Invocation(
                executable: executable,
                arguments: arguments,
                standardInput: standardInput,
                currentDirectory: currentDirectory
            ))
        guard let currentDirectory else {
            return CommandOutput(status: 64, standardOutput: "", standardError: "missing current directory")
        }
        switch behavior {
        case .valid(let name):
            try Self.writePackage(name: name, at: currentDirectory.appending(path: "draft", directoryHint: .isDirectory))
            return CommandOutput(status: 0, standardOutput: "{\"type\":\"turn.completed\"}\n", standardError: "")
        case .completeReviewInventory(let name):
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: name, at: package)
            let skill = package.appending(path: "skills/\(name)", directoryHint: .isDirectory)
            let script = skill.appending(path: "scripts/run.sh", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\necho reviewed\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: script.path(percentEncoded: false)
            )
            let boundaryFile = skill.appending(
                path: "references/one/two/three/four/review.md",
                directoryHint: .notDirectory
            )
            try FileManager.default.createDirectory(
                at: boundaryFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "Review this supporting reference.\n".write(to: boundaryFile, atomically: true, encoding: .utf8)
            let asset = skill.appending(path: "assets/icon.dat", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x00, 0xFF, 0x42]).write(to: asset)
            return CommandOutput(status: 0, standardOutput: "{}\n", standardError: "")
        case .hiddenNestedFile(let name):
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: name, at: package)
            let hidden = package.appending(
                path: "skills/\(name)/references/.unreviewed.md",
                directoryHint: .notDirectory
            )
            try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "This file must not bypass review.\n".write(to: hidden, atomically: true, encoding: .utf8)
            return CommandOutput(status: 0, standardOutput: "{}\n", standardError: "")
        case .overDepthFile(let name):
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: name, at: package)
            let tooDeep = package.appending(
                path: "skills/\(name)/references/one/two/three/four/five/unreviewed.md",
                directoryHint: .notDirectory
            )
            try FileManager.default.createDirectory(at: tooDeep.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "This file is deeper than the review contract.\n".write(to: tooDeep, atomically: true, encoding: .utf8)
            return CommandOutput(status: 0, standardOutput: "{}\n", standardError: "")
        case .twoSkills:
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: "first-skill", at: package)
            let second = package.appending(path: "skills/second-skill", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try Self.skillMarkdown(name: "second-skill").write(
                to: second.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            return CommandOutput(status: 0, standardOutput: "{}\n", standardError: "")
        case .symbolicLink:
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: "linked-skill", at: package)
            let references = package.appending(path: "skills/linked-skill/references")
            try FileManager.default.createSymbolicLink(at: references, withDestinationURL: URL(filePath: "/tmp"))
            return CommandOutput(status: 0, standardOutput: "{}\n", standardError: "")
        case .failure:
            return CommandOutput(
                status: 1,
                standardOutput: "",
                standardError: "Authorization: Bearer secret-token-value could not run"
            )
        case .successWithoutDraft:
            return CommandOutput(status: 0, standardOutput: "{\"type\":\"turn.completed\"}\n", standardError: "")
        }
    }

    func recordedInvocations() -> [Invocation] { invocations }

    fileprivate static func writePackage(name: String, at packageURL: URL) throws {
        let skillURL = packageURL.appending(path: "skills/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
        let manifest = try AgentPluginManifest(name: name, description: "A generated test skill")
        let data = try AgentToolingCoding.encoder().encode(manifest)
        try data.write(to: packageURL.appending(path: "plugin.json"), options: .atomic)
        try skillMarkdown(name: name).write(
            to: skillURL.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func skillMarkdown(name: String) -> String {
        """
        ---
        name: \(name)
        description: Review a generated skill without installing it.
        ---

        # Generated Skill

        Follow the user's requested workflow.
        """
    }
}

private actor BlockingCodexSkillDraftRunner: StandardInputCommandRunning {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func run(
        executable _: String,
        arguments _: [String],
        standardInput _: Data,
        currentDirectory: URL?
    ) async throws -> CommandOutput {
        didStart = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        guard let currentDirectory else {
            return CommandOutput(status: 64, standardOutput: "", standardError: "missing current directory")
        }
        try CodexSkillDraftRunnerStub.writePackage(
            name: "concurrent-draft",
            at: currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
        )
        return CommandOutput(status: 0, standardOutput: "{}\n", standardError: "")
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

struct CodexSkillDraftServiceTests {
    @Test func stagesValidSkillForReviewUsingCodexAndStandardInput() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.valid(name: "release-review"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )
        let instruction = "Create a skill that reviews release readiness and reports blocking evidence."

        let result = try await service.createDraft(
            CodexSkillDraftRequest(
                instruction: instruction,
                proposedName: "release-review",
                scope: .project,
                projectRoot: "/Users/example/work/project/../project",
                targets: [.gemini, .codex, .codex]
            ))

        #expect(result.skillName == "release-review")
        #expect(result.manifest.name == "release-review")
        #expect(result.request.projectRoot == "/Users/example/work/project")
        #expect(result.request.targets == [.codex, .gemini])
        #expect(result.files.map(\.relativePath) == ["plugin.json", "skills/release-review/SKILL.md"])
        #expect(result.files.allSatisfy { !$0.isExecutable })
        #expect(result.fingerprint.count == 64)
        #expect(FileManager.default.fileExists(atPath: result.packageURL.path(percentEncoded: false)))

        let invocation = try #require(await runner.recordedInvocations().only)
        #expect(invocation.executable == "codex")
        #expect(invocation.arguments.prefix(2) == ["exec", "--json"])
        #expect(invocation.arguments.contains("--ephemeral"))
        #expect(invocation.arguments.contains("--ignore-user-config"))
        #expect(invocation.arguments.contains("--ignore-rules"))
        let optionPairs = Array(zip(invocation.arguments, invocation.arguments.dropFirst()))
        #expect(optionPairs.contains { $0 == "--disable" && $1 == "plugins" })
        #expect(optionPairs.contains { $0 == "--disable" && $1 == "hooks" })
        #expect(optionPairs.contains { $0 == "--disable" && $1 == "apps" })
        #expect(optionPairs.contains { $0 == "--disable" && $1 == "remote_plugin" })
        #expect(optionPairs.contains { $0 == "--enable" && $1 == "code_mode_host" })
        #expect(invocation.arguments.contains("workspace-write"))
        #expect(invocation.arguments.last == "-")
        #expect(!invocation.arguments.contains(where: { $0.contains(instruction) }))
        let prompt = String(decoding: invocation.standardInput, as: UTF8.self)
        #expect(prompt.contains("Use `$skill-creator`"))
        #expect(prompt.contains(instruction))
        #expect(prompt.contains("do not install"))
        #expect(invocation.currentDirectory?.lastPathComponent.hasPrefix("request-") == true)
    }

    @Test func rejectsMultipleGeneratedSkillsAndRemovesFailedStagingRequest() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.twoSkills)
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(CodexSkillDraftRequest(instruction: "Create one narrow release skill."))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    @Test func enumeratesEveryRegularFileInTheBoundedReviewInventory() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.completeReviewInventory(name: "complete-review"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        let result = try await service.createDraft(
            CodexSkillDraftRequest(instruction: "Create a complete review draft.", proposedName: "complete-review")
        )

        #expect(
            result.files.map(\.relativePath) == [
                "plugin.json",
                "skills/complete-review/SKILL.md",
                "skills/complete-review/assets/icon.dat",
                "skills/complete-review/references/one/two/three/four/review.md",
                "skills/complete-review/scripts/run.sh",
            ]
        )
        #expect(result.files.first(where: { $0.relativePath.hasSuffix("run.sh") })?.isExecutable == true)
        #expect(result.files.first(where: { $0.relativePath.hasSuffix("icon.dat") })?.textContent == nil)
    }

    @Test func rejectsHiddenNestedFilesInsteadOfSilentlyExcludingThemFromReview() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.hiddenNestedFile(name: "hidden-review"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        do {
            _ = try await service.createDraft(
                CodexSkillDraftRequest(instruction: "Create a hidden review draft.", proposedName: "hidden-review")
            )
            Issue.record("Expected the hidden file to be rejected")
        } catch let error as CodexSkillDraftError {
            #expect(error.localizedDescription.contains("Hidden package item"))
            #expect(error.localizedDescription.contains(".unreviewed.md"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false)).isEmpty)
    }

    @Test func rejectsFilesBeyondTheReviewDepthInsteadOfSilentlyExcludingThem() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.overDepthFile(name: "deep-review"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        do {
            _ = try await service.createDraft(
                CodexSkillDraftRequest(instruction: "Create a deep review draft.", proposedName: "deep-review")
            )
            Issue.record("Expected the over-depth file to be rejected")
        } catch let error as CodexSkillDraftError {
            #expect(error.localizedDescription.contains("maximum review depth"))
            #expect(error.localizedDescription.contains("unreviewed.md"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false)).isEmpty)
    }

    @Test func discardIsIdempotentAndRejectsAResultOutsideItsRequestDirectory() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.valid(name: "review-draft"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )
        let result = try await service.createDraft(
            CodexSkillDraftRequest(instruction: "Create a review draft.", proposedName: "review-draft")
        )

        try await service.discardDraft(result)
        try await service.discardDraft(result)
        #expect(!FileManager.default.fileExists(atPath: result.packageURL.path(percentEncoded: false)))

        var forged = result
        forged.packageURL = fixture.root.appending(path: "unrelated", directoryHint: .isDirectory)
        await #expect(throws: CodexSkillDraftError.self) {
            try await service.discardDraft(forged)
        }
    }

    @Test func recoversACompletePersistedDraftWithoutRunningCodexAgain() async throws {
        let fixture = try makeFixture()
        let request = CodexSkillDraftRequest(
            instruction: "Create a recoverable draft.",
            proposedName: "recoverable-draft"
        )
        let initialRunner = CodexSkillDraftRunnerStub(.valid(name: "recoverable-draft"))
        let initialService = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: initialRunner,
            skillCreatorURL: fixture.skillCreator
        )
        let initial = try await initialService.createDraft(request)

        let recoveryRunner = CodexSkillDraftRunnerStub(.failure)
        let recovered = try await CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: recoveryRunner,
            skillCreatorURL: fixture.skillCreator
        ).createDraft(request)

        #expect(recovered.skillName == initial.skillName)
        #expect(recovered.fingerprint == initial.fingerprint)
        #expect(await recoveryRunner.recordedInvocations().isEmpty)
    }

    @Test func retriesAnIncompletePersistedRequestFromACleanDirectory() async throws {
        let fixture = try makeFixture()
        let request = CodexSkillDraftRequest(
            id: UUID(),
            instruction: "Create a retried draft.",
            proposedName: "retried-draft"
        )
        let requestURL = fixture.staging.appending(
            path: "request-\(request.id.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: requestURL, withIntermediateDirectories: true)
        let metadata = try AgentToolingCoding.encoder().encode(request)
        try metadata.write(
            to: requestURL.appending(path: CodexSkillDraftService.requestMetadataFileName),
            options: .atomic
        )
        try "partial".write(
            to: requestURL.appending(path: "unfinished.txt"),
            atomically: true,
            encoding: .utf8
        )
        let runner = CodexSkillDraftRunnerStub(.valid(name: "retried-draft"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        let result = try await service.createDraft(request)

        #expect(result.skillName == "retried-draft")
        #expect(await runner.recordedInvocations().count == 1)
        #expect(!FileManager.default.fileExists(atPath: requestURL.appending(path: "unfinished.txt").path(percentEncoded: false)))
    }

    @Test func doesNotReuseOrDeleteAStageWhosePersistedRequestDiffers() async throws {
        let fixture = try makeFixture()
        let requestID = UUID()
        let persisted = CodexSkillDraftRequest(
            id: requestID,
            instruction: "The original instruction.",
            proposedName: "original-draft"
        )
        let requestURL = fixture.staging.appending(
            path: "request-\(requestID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: requestURL, withIntermediateDirectories: true)
        try AgentToolingCoding.encoder().encode(persisted).write(
            to: requestURL.appending(path: CodexSkillDraftService.requestMetadataFileName),
            options: .atomic
        )
        let marker = requestURL.appending(path: "keep-me")
        try Data().write(to: marker)
        let runner = CodexSkillDraftRunnerStub(.valid(name: "replacement-draft"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(
                CodexSkillDraftRequest(
                    id: requestID,
                    instruction: "A different instruction.",
                    proposedName: "replacement-draft"
                ))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test func duplicateSameProcessRequestCannotDeleteAnInFlightDraft() async throws {
        let fixture = try makeFixture()
        let runner = BlockingCodexSkillDraftRunner()
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )
        let request = CodexSkillDraftRequest(
            instruction: "Create a concurrent draft.",
            proposedName: "concurrent-draft"
        )
        let first = Task { try await service.createDraft(request) }
        await runner.waitUntilStarted()

        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(request)
        }
        await #expect(throws: CodexSkillDraftError.self) {
            try await service.discardRequest(id: request.id)
        }

        await runner.release()
        let result = try await first.value
        #expect(result.skillName == "concurrent-draft")
        #expect(FileManager.default.fileExists(atPath: result.packageURL.path(percentEncoded: false)))
    }

    @Test func rejectsSymbolicLinksInGeneratedPackage() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.symbolicLink)
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(
                CodexSkillDraftRequest(instruction: "Create a linked skill.", proposedName: "linked-skill")
            )
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    @Test func validatesRequestBeforeLaunchingCodex() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.valid(name: "unused"))
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(CodexSkillDraftRequest(instruction: " "))
        }
        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(
                CodexSkillDraftRequest(instruction: "Project skill", scope: .project, projectRoot: nil)
            )
        }
        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(
                CodexSkillDraftRequest(instruction: "Local project skill", scope: .localProject, projectRoot: "/tmp/project")
            )
        }
        await #expect(throws: CodexSkillDraftError.self) {
            try await service.createDraft(CodexSkillDraftRequest(instruction: "No target", targets: []))
        }
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test func rejectsProtectedAndSymbolicLinkStagingRootsWithoutChangingThem() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.valid(name: "unused"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let permissionsBefore = try #require(
            (FileManager.default.attributesOfItem(atPath: home.path(percentEncoded: false))[.posixPermissions] as? NSNumber)?
                .intValue
        )
        let protectedService = CodexSkillDraftService(
            stagingRootURL: home,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        await #expect(throws: CodexSkillDraftError.self) {
            try await protectedService.createDraft(CodexSkillDraftRequest(instruction: "Do not write here."))
        }
        let permissionsAfter = try #require(
            (FileManager.default.attributesOfItem(atPath: home.path(percentEncoded: false))[.posixPermissions] as? NSNumber)?
                .intValue
        )
        #expect(permissionsAfter == permissionsBefore)

        let actual = fixture.root.appending(path: "actual-staging", directoryHint: .isDirectory)
        let linked = fixture.root.appending(path: "linked-staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        let linkedService = CodexSkillDraftService(
            stagingRootURL: linked,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )
        await #expect(throws: CodexSkillDraftError.self) {
            try await linkedService.createDraft(CodexSkillDraftRequest(instruction: "Do not follow this link."))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path(percentEncoded: false)).isEmpty)
    }

    @Test func reportsRedactedCodexFailureAndCleansStagingRequest() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.failure)
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        do {
            _ = try await service.createDraft(CodexSkillDraftRequest(instruction: "Create a release skill."))
            Issue.record("Expected Codex to fail")
        } catch let error as CodexSkillDraftError {
            #expect(error.localizedDescription.contains("Bearer [redacted]"))
            #expect(!error.localizedDescription.contains("secret-token-value"))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    @Test func reportsClearErrorWhenCodexExitsSuccessfullyWithoutADraft() async throws {
        let fixture = try makeFixture()
        let runner = CodexSkillDraftRunnerStub(.successWithoutDraft)
        let service = CodexSkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator
        )

        do {
            _ = try await service.createDraft(CodexSkillDraftRequest(instruction: "Create a release skill."))
            Issue.record("Expected the missing draft to be reported")
        } catch let error as CodexSkillDraftError {
            guard case .missingPackage = error else {
                Issue.record("Expected missingPackage, got \(error)")
                return
            }
            #expect(error.localizedDescription == "Codex did not create a draft package.")
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    @Test func processRunnerResolvesPATHInstalledCodexSymlinkToCanonicalExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ProcessRunnerExecutableTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let canonical = root.appending(path: "canonical-codex", directoryHint: .notDirectory)
        let installed = bin.appending(path: "codex", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: canonical, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: canonical.path(percentEncoded: false))
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: canonical)

        let resolved = ProcessCommandRunner.canonicalExecutableURL(
            for: "codex",
            environment: ["PATH": bin.path(percentEncoded: false)],
            currentDirectory: nil
        )

        #expect(resolved?.path(percentEncoded: false) == canonical.resolvingSymlinksInPath().path(percentEncoded: false))
    }

    @Test func processRunnerWritesBoundedStandardInputWithoutAShell() async throws {
        let runner = ProcessCommandRunner(timeout: .seconds(3))
        let input = Data("skill instruction from stdin\n".utf8)
        let result = try await runner.run(
            executable: "/bin/cat",
            arguments: [],
            standardInput: input,
            currentDirectory: nil
        )

        #expect(result.status == 0)
        #expect(result.standardOutput == "skill instruction from stdin\n")
        #expect(result.standardError.isEmpty)
    }

    @Test func processRunnerRejectsOversizedStandardInputBeforeLaunch() async {
        let runner = ProcessCommandRunner(timeout: .seconds(3))
        await #expect(throws: ProcessCommandRunnerError.self) {
            try await runner.run(
                executable: "/bin/cat",
                arguments: [],
                standardInput: Data(repeating: 0x61, count: 1_048_577),
                currentDirectory: nil
            )
        }
    }

    private func makeFixture() throws -> (root: URL, staging: URL, skillCreator: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CodexSkillDraftServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let skillCreator = root.appending(path: "codex/skills/.system/skill-creator/SKILL.md")
        try FileManager.default.createDirectory(at: skillCreator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: skill-creator\ndescription: Create a skill.\n---\n".write(
            to: skillCreator,
            atomically: true,
            encoding: .utf8
        )
        return (root, staging, skillCreator)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
