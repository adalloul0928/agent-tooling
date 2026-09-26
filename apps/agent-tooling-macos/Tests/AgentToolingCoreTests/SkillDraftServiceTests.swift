import Foundation
import Testing

@testable import AgentToolingCore

private actor SkillDraftRunnerStub: StandardInputCommandRunning {
    enum Behavior: Sendable {
        case valid(name: String)
        case completeReviewInventory(name: String)
        case hiddenNestedFile(name: String)
        case overDepthFile(name: String)
        case twoSkills
        case symbolicLink
        case failure
        case successWithoutDraft
        case questionThenDraft(name: String)
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
        let reply = Self.replyOutput(executable: executable, arguments: arguments)
        switch behavior {
        case .valid(let name):
            try Self.writePackage(name: name, at: currentDirectory.appending(path: "draft", directoryHint: .isDirectory))
            return CommandOutput(status: 0, standardOutput: reply, standardError: "")
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
            return CommandOutput(status: 0, standardOutput: reply, standardError: "")
        case .hiddenNestedFile(let name):
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: name, at: package)
            let hidden = package.appending(
                path: "skills/\(name)/references/.unreviewed.md",
                directoryHint: .notDirectory
            )
            try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "This file must not bypass review.\n".write(to: hidden, atomically: true, encoding: .utf8)
            return CommandOutput(status: 0, standardOutput: reply, standardError: "")
        case .overDepthFile(let name):
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: name, at: package)
            let tooDeep = package.appending(
                path: "skills/\(name)/references/one/two/three/four/five/unreviewed.md",
                directoryHint: .notDirectory
            )
            try FileManager.default.createDirectory(at: tooDeep.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "This file is deeper than the review contract.\n".write(to: tooDeep, atomically: true, encoding: .utf8)
            return CommandOutput(status: 0, standardOutput: reply, standardError: "")
        case .twoSkills:
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: "first-skill", at: package)
            let second = package.appending(path: "skills/second-skill", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try Self.skillMarkdown(name: "second-skill").write(
                to: second.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            return CommandOutput(status: 0, standardOutput: reply, standardError: "")
        case .symbolicLink:
            let package = currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
            try Self.writePackage(name: "linked-skill", at: package)
            let references = package.appending(path: "skills/linked-skill/references")
            try FileManager.default.createSymbolicLink(at: references, withDestinationURL: URL(filePath: "/tmp"))
            return CommandOutput(status: 0, standardOutput: reply, standardError: "")
        case .failure:
            return CommandOutput(
                status: 1,
                standardOutput: "",
                standardError: "Authorization: Bearer secret-token-value could not run"
            )
        case .successWithoutDraft:
            return CommandOutput(status: 0, standardOutput: reply, standardError: "")
        case .questionThenDraft(let name):
            // The first turn asks; the second writes. Which turn this is shows
            // in the arguments: a start names the folder, a resume names the
            // conversation.
            if Self.isResume(arguments) {
                try Self.writePackage(name: name, at: currentDirectory.appending(path: "draft", directoryHint: .isDirectory))
                return CommandOutput(
                    status: 0,
                    standardOutput: Self.replyOutput(
                        executable: executable, arguments: arguments, text: "Done. I wrote the package at ./draft."),
                    standardError: "")
            }
            return CommandOutput(
                status: 0,
                standardOutput: Self.replyOutput(
                    executable: executable, arguments: arguments, text: "Which checks matter most to you?"),
                standardError: "")
        }
    }

    /// One turn's output in the client's own wire format: Claude prints one
    /// JSON document, Codex one JSON event per line. Both name the session.
    static func replyOutput(executable: String, arguments: [String], text: String = "I wrote the draft.") -> String {
        if executable == "claude" {
            let sessionID = arguments.firstIndex(where: { $0 == "--session-id" || $0 == "--resume" })
                .map { arguments[$0 + 1] } ?? "00000000-0000-0000-0000-000000000000"
            return """
                {"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"num_turns":3,\
                "result":\(Self.jsonString(text)),"session_id":"\(sessionID)","permission_denials":[]}

                """
        }
        let threadID = isResume(arguments) ? arguments[2] : codexThreadID
        return """
            {"type":"thread.started","thread_id":"\(threadID)"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":\(Self.jsonString(text))}}
            {"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}

            """
    }

    static let codexThreadID = "0199a1b2-c3d4-7e5f-8a6b-0c1d2e3f4a5b"

    static func isResume(_ arguments: [String]) -> Bool {
        arguments.count > 2 && arguments[1] == "resume" || arguments.contains("--resume")
    }

    private static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        var literal = String(decoding: data, as: UTF8.self)
        literal.removeFirst()
        literal.removeLast()
        return literal
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
        try SkillDraftRunnerStub.writePackage(
            name: "concurrent-draft",
            at: currentDirectory.appending(path: "draft", directoryHint: .isDirectory)
        )
        return CommandOutput(
            status: 0, standardOutput: SkillDraftRunnerStub.replyOutput(executable: "codex", arguments: []),
            standardError: "")
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

struct SkillDraftServiceTests {
    @Test func stagesValidSkillForReviewUsingCodexAndStandardInput() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.valid(name: "release-review"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        let instruction = "Create a skill that reviews release readiness and reports blocking evidence."

        let result = try await service.createDraft(
            SkillDraftRequest(
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
        // The thread is kept so a later turn can resume it, and the person's
        // own Codex configuration is kept so their sign-in is used.
        #expect(!invocation.arguments.contains("--ephemeral"))
        #expect(!invocation.arguments.contains("--ignore-user-config"))
        #expect(invocation.arguments.contains("--ignore-rules"))
        #expect(invocation.arguments == SkillCreatorCommandShapes.codexStart(requestDirectory: invocation.currentDirectory!))
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

    // MARK: - Conversations

    @Test func aClaudeConversationStartsWithAChosenSessionAndResumesIt() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.questionThenDraft(name: "release-review"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        let request = SkillDraftRequest(
            client: .claude, instruction: "Make a skill for releases.", proposedName: "release-review", targets: [.claude])

        let first = try await service.startConversation(request)
        #expect(first.reply.role == .assistant)
        #expect(first.reply.text == "Which checks matter most to you?")
        #expect(first.draft == nil, "a question wrote a package")
        #expect(first.draftIssue == nil)

        let second = try await service.continueConversation(requestID: request.id, reply: "Tests and rollback notes.")
        #expect(second.reply.text == "Done. I wrote the package at ./draft.")
        #expect(second.draft?.skillName == "release-review")
        #expect(second.draft?.request.client == .claude)

        let invocations = await runner.recordedInvocations()
        #expect(invocations.count == 2)
        // Nothing is installed in the fixture home, so the bare name is what runs.
        #expect(invocations.allSatisfy { $0.executable == "claude" })
        // The start chooses the session; the resume names the same one.
        let start = try #require(invocations.first)
        let sessionID = try #require(UUID(uuidString: start.arguments[4]))
        #expect(start.arguments == SkillCreatorCommandShapes.claude(sessionID: sessionID, resuming: false))
        #expect(invocations[1].arguments == SkillCreatorCommandShapes.claude(sessionID: sessionID, resuming: true))
        // Both turns run inside the request folder, and the prompt never
        // travels on the command line.
        #expect(invocations.allSatisfy { $0.currentDirectory?.lastPathComponent.hasPrefix("request-") == true })
        #expect(!start.arguments.contains { $0.contains("releases") })
        let kickoff = String(decoding: start.standardInput, as: UTF8.self)
        #expect(kickoff.contains("/skill-creator:skill-creator"))
        #expect(kickoff.contains("Make a skill for releases."))
        #expect(kickoff.contains("Bash is not available"))
        let followUp = String(decoding: invocations[1].standardInput, as: UTF8.self)
        #expect(followUp.hasPrefix("Tests and rollback notes."))

        // The exchange is kept beside the draft, so a reopened sheet shows it.
        let conversation = try #require(try await service.conversation(for: request.id))
        #expect(conversation.sessionID == sessionID.uuidString.lowercased())
        #expect(conversation.messages.map(\.role) == [.person, .assistant, .person, .assistant])
        #expect(try await service.currentDraft(for: request.id)?.skillName == "release-review")
    }

    @Test func aCodexConversationStartsAThreadAndResumesTheOneCodexNamed() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.questionThenDraft(name: "release-review"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        let request = SkillDraftRequest(
            client: .codex, instruction: "Make a skill for releases.", proposedName: "release-review", targets: [.codex])

        let first = try await service.startConversation(request)
        #expect(first.draft == nil)
        let second = try await service.continueConversation(requestID: request.id, reply: "Tests and rollback notes.")
        #expect(second.draft?.skillName == "release-review")

        let invocations = await runner.recordedInvocations()
        #expect(invocations.count == 2)
        #expect(invocations.allSatisfy { $0.executable == "codex" })
        let requestURL = try #require(invocations[0].currentDirectory)
        #expect(invocations[0].arguments == SkillCreatorCommandShapes.codexStart(requestDirectory: requestURL))
        // Codex names its own thread; the resume uses that name, not a UUID
        // this app made up.
        #expect(invocations[1].arguments == SkillCreatorCommandShapes.codexResume(threadID: SkillDraftRunnerStub.codexThreadID))
        #expect(invocations[1].arguments.contains("sandbox_mode=workspace-write"))
        let kickoff = String(decoding: invocations[0].standardInput, as: UTF8.self)
        #expect(kickoff.contains("Use `$skill-creator`"))
        #expect(kickoff.contains(fixture.skillCreator.path(percentEncoded: false)))

        let conversation = try #require(try await service.conversation(for: request.id))
        #expect(conversation.sessionID == SkillDraftRunnerStub.codexThreadID)
    }

    @Test func aCodexTurnThatOnlyWarnsAboutConfigurationIsNotANote() async throws {
        let output = CommandOutput(
            status: 0,
            standardOutput: """
                {"type":"thread.started","thread_id":"\(SkillDraftRunnerStub.codexThreadID)"}
                {"type":"item.completed","item":{"id":"e","type":"error","message":"Codex is ignoring 1 unrecognized configuration setting. Check for typos."}}
                {"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Here is the draft."}}
                {"type":"turn.completed","usage":{}}

                """,
            standardError: "")

        let parsed = try CodexSkillCreatorAdapter().parse(output)

        #expect(parsed.reply == "Here is the draft.")
        #expect(parsed.sessionID == SkillDraftRunnerStub.codexThreadID)
        #expect(parsed.notes.isEmpty, "a warning about the person's own config was shown as a note")
        #expect(!parsed.failed)
    }

    @Test func aClaudeTurnReportsRefusedToolsAsANote() async throws {
        let output = CommandOutput(
            status: 0,
            standardOutput: """
                {"type":"result","subtype":"success","is_error":false,"result":"I could not run the script.",\
                "session_id":"0713e13c-aa59-4b1f-8872-ea3e559d57ea",\
                "permission_denials":[{"tool_name":"Bash","tool_input":{"command":"python3 x.py"}}]}
                """,
            standardError: "")

        let parsed = try ClaudeSkillCreatorAdapter().parse(output)

        #expect(parsed.reply == "I could not run the script.")
        #expect(parsed.sessionID == "0713e13c-aa59-4b1f-8872-ea3e559d57ea")
        #expect(parsed.notes.count == 1)
        #expect(parsed.notes[0].contains("Bash"))
        #expect(!parsed.failed)
    }

    @Test func continuingAConversationNobodyStartedIsRefusedWithoutRunningAnything() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.valid(name: "unused"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        await #expect(throws: SkillDraftError.self) {
            try await service.continueConversation(requestID: UUID(), reply: "Anything.")
        }
        await #expect(throws: SkillDraftError.self) {
            try await service.startConversation(SkillDraftRequest(client: .gemini, instruction: "A Gemini skill."))
        }
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test func aFailedFirstTurnLeavesNoStageBehind() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.failure)
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        let request = SkillDraftRequest(client: .claude, instruction: "Make a skill for releases.", targets: [.claude])

        do {
            _ = try await service.startConversation(request)
            Issue.record("Expected the turn to fail")
        } catch let error as SkillDraftError {
            #expect(error.localizedDescription.contains("Bearer [redacted]"))
            #expect(!error.localizedDescription.contains("secret-token-value"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false)).isEmpty)
        #expect(try await service.conversation(for: request.id) == nil)
    }

    // MARK: - Availability

    @Test func reportsEachClientsSkillCreatorAndTheCommandsThatInstallIt() async throws {
        let fixture = try makeFixture(claudeHasSkillCreator: false)
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: SkillDraftRunnerStub(.valid(name: "unused")),
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        #expect(await service.skillCreatorAvailability(for: .codex) == .available)
        #expect(await service.skillCreatorAvailability(for: .gemini) == .unsupportedClient)
        guard case .missing(let reason, let install) = await service.skillCreatorAvailability(for: .claude) else {
            Issue.record("expected Claude's creator to be missing")
            return
        }
        #expect(reason.contains("skill-creator"))
        // The marketplace is already known here, so only the install remains.
        #expect(install.map(\.arguments) == [SkillCreatorCommandShapes.claudeSkillCreatorInstallArguments])
        #expect(install.allSatisfy { $0.executable == "claude" })

        // Starting a conversation with a client whose creator is missing runs
        // nothing and says why.
        let runner = SkillDraftRunnerStub(.valid(name: "unused"))
        let refusing = SkillDraftService(
            stagingRootURL: fixture.staging, runner: runner, skillCreatorURL: fixture.skillCreator, homeURL: fixture.root)
        await #expect(throws: SkillDraftError.self) {
            try await refusing.startConversation(SkillDraftRequest(client: .claude, instruction: "A Claude skill."))
        }
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test func offersTheMarketplaceFirstWhenClaudeDoesNotKnowIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SkillCreatorLocator-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appending(path: ".claude/plugins", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try #"{"version":2,"plugins":{}}"#.write(
            to: plugins.appending(path: "installed_plugins.json"), atomically: true, encoding: .utf8)

        guard case .missing(_, let install) = SkillCreatorLocator.claudeAvailability(homeURL: root, environment: [:]) else {
            Issue.record("expected the creator to be missing")
            return
        }
        #expect(install.map(\.arguments) == [
            SkillCreatorCommandShapes.claudeOfficialMarketplaceAddArguments,
            SkillCreatorCommandShapes.claudeSkillCreatorInstallArguments,
        ])
        // Every step the offer would run is one the policy admits.
        let policy = OperationCommandPolicy(
            libraryURL: root.appending(path: "library"), gitBackupRoot: root.appending(path: "backup"), homeURL: root)
        for command in install {
            #expect(throws: Never.self) { try policy.validate(executable: command.executable, arguments: command.arguments) }
        }
    }

    @Test func thePolicyAdmitsExactlyTheCreatorShapesAndNothingNear() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let policy = OperationCommandPolicy(
            libraryURL: home.appending(path: "library"), gitBackupRoot: home.appending(path: "backup"), homeURL: home)
        let sessionID = UUID()
        let requestDirectory = home.appending(
            path: "Library/Application Support/Agent Tooling/cache/skill-drafts/request-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)

        #expect(throws: Never.self) {
            try policy.validate(executable: "claude", arguments: SkillCreatorCommandShapes.claude(sessionID: sessionID, resuming: false))
            try policy.validate(executable: "claude", arguments: SkillCreatorCommandShapes.claude(sessionID: sessionID, resuming: true))
            try policy.validate(executable: "codex", arguments: SkillCreatorCommandShapes.codexStart(requestDirectory: requestDirectory))
            try policy.validate(
                executable: "codex", arguments: SkillCreatorCommandShapes.codexResume(threadID: SkillDraftRunnerStub.codexThreadID))
        }

        // A permission mode the shape does not name, a folder outside the
        // home, a folder that is not a request folder, a thread that is not a
        // UUID: each is one token off and each is refused.
        var permissive = SkillCreatorCommandShapes.claude(sessionID: sessionID, resuming: false)
        permissive[permissive.firstIndex(of: "acceptEdits")!] = "bypassPermissions"
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: permissive) }
        #expect(throws: OperationEngineError.self) {
            try policy.validate(
                executable: "codex",
                arguments: SkillCreatorCommandShapes.codexStart(
                    requestDirectory: URL(filePath: "/tmp/request-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)))
        }
        #expect(throws: OperationEngineError.self) {
            try policy.validate(
                executable: "codex",
                arguments: SkillCreatorCommandShapes.codexStart(requestDirectory: home.appending(path: "Documents", directoryHint: .isDirectory)))
        }
        #expect(throws: OperationEngineError.self) {
            try policy.validate(executable: "codex", arguments: SkillCreatorCommandShapes.codexResume(threadID: "latest"))
        }
        var wider = SkillCreatorCommandShapes.codexStart(requestDirectory: requestDirectory)
        wider[wider.firstIndex(of: "workspace-write")!] = "danger-full-access"
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "codex", arguments: wider) }
    }

    @Test func rejectsMultipleGeneratedSkillsAndRemovesFailedStagingRequest() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.twoSkills)
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(SkillDraftRequest(instruction: "Create one narrow release skill."))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    @Test func enumeratesEveryRegularFileInTheBoundedReviewInventory() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.completeReviewInventory(name: "complete-review"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        let result = try await service.createDraft(
            SkillDraftRequest(instruction: "Create a complete review draft.", proposedName: "complete-review")
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
        let runner = SkillDraftRunnerStub(.hiddenNestedFile(name: "hidden-review"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        do {
            _ = try await service.createDraft(
                SkillDraftRequest(instruction: "Create a hidden review draft.", proposedName: "hidden-review")
            )
            Issue.record("Expected the hidden file to be rejected")
        } catch let error as SkillDraftError {
            #expect(error.localizedDescription.contains("Hidden package item"))
            #expect(error.localizedDescription.contains(".unreviewed.md"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false)).isEmpty)
    }

    @Test func rejectsFilesBeyondTheReviewDepthInsteadOfSilentlyExcludingThem() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.overDepthFile(name: "deep-review"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        do {
            _ = try await service.createDraft(
                SkillDraftRequest(instruction: "Create a deep review draft.", proposedName: "deep-review")
            )
            Issue.record("Expected the over-depth file to be rejected")
        } catch let error as SkillDraftError {
            #expect(error.localizedDescription.contains("maximum review depth"))
            #expect(error.localizedDescription.contains("unreviewed.md"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false)).isEmpty)
    }

    @Test func discardIsIdempotentAndRejectsAResultOutsideItsRequestDirectory() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.valid(name: "review-draft"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        let result = try await service.createDraft(
            SkillDraftRequest(instruction: "Create a review draft.", proposedName: "review-draft")
        )

        try await service.discardDraft(result)
        try await service.discardDraft(result)
        #expect(!FileManager.default.fileExists(atPath: result.packageURL.path(percentEncoded: false)))

        var forged = result
        forged.packageURL = fixture.root.appending(path: "unrelated", directoryHint: .isDirectory)
        await #expect(throws: SkillDraftError.self) {
            try await service.discardDraft(forged)
        }
    }

    @Test func recoversACompletePersistedDraftWithoutRunningCodexAgain() async throws {
        let fixture = try makeFixture()
        let request = SkillDraftRequest(
            instruction: "Create a recoverable draft.",
            proposedName: "recoverable-draft"
        )
        let initialRunner = SkillDraftRunnerStub(.valid(name: "recoverable-draft"))
        let initialService = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: initialRunner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        let initial = try await initialService.createDraft(request)

        let recoveryRunner = SkillDraftRunnerStub(.failure)
        let recovered = try await SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: recoveryRunner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        ).createDraft(request)

        #expect(recovered.skillName == initial.skillName)
        #expect(recovered.fingerprint == initial.fingerprint)
        #expect(await recoveryRunner.recordedInvocations().isEmpty)
    }

    @Test func retriesAnIncompletePersistedRequestFromACleanDirectory() async throws {
        let fixture = try makeFixture()
        let request = SkillDraftRequest(
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
            to: requestURL.appending(path: SkillDraftService.requestMetadataFileName),
            options: .atomic
        )
        try "partial".write(
            to: requestURL.appending(path: "unfinished.txt"),
            atomically: true,
            encoding: .utf8
        )
        let runner = SkillDraftRunnerStub(.valid(name: "retried-draft"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        let result = try await service.createDraft(request)

        #expect(result.skillName == "retried-draft")
        #expect(await runner.recordedInvocations().count == 1)
        #expect(!FileManager.default.fileExists(atPath: requestURL.appending(path: "unfinished.txt").path(percentEncoded: false)))
    }

    @Test func doesNotReuseOrDeleteAStageWhosePersistedRequestDiffers() async throws {
        let fixture = try makeFixture()
        let requestID = UUID()
        let persisted = SkillDraftRequest(
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
            to: requestURL.appending(path: SkillDraftService.requestMetadataFileName),
            options: .atomic
        )
        let marker = requestURL.appending(path: "keep-me")
        try Data().write(to: marker)
        let runner = SkillDraftRunnerStub(.valid(name: "replacement-draft"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(
                SkillDraftRequest(
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
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        let request = SkillDraftRequest(
            instruction: "Create a concurrent draft.",
            proposedName: "concurrent-draft"
        )
        let first = Task { try await service.createDraft(request) }
        await runner.waitUntilStarted()

        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(request)
        }
        await #expect(throws: SkillDraftError.self) {
            try await service.discardRequest(id: request.id)
        }

        await runner.release()
        let result = try await first.value
        #expect(result.skillName == "concurrent-draft")
        #expect(FileManager.default.fileExists(atPath: result.packageURL.path(percentEncoded: false)))
    }

    @Test func rejectsSymbolicLinksInGeneratedPackage() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.symbolicLink)
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(
                SkillDraftRequest(instruction: "Create a linked skill.", proposedName: "linked-skill")
            )
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    @Test func validatesRequestBeforeLaunchingCodex() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.valid(name: "unused"))
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(SkillDraftRequest(instruction: " "))
        }
        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(
                SkillDraftRequest(instruction: "Project skill", scope: .project, projectRoot: nil)
            )
        }
        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(
                SkillDraftRequest(instruction: "Local project skill", scope: .localProject, projectRoot: "/tmp/project")
            )
        }
        await #expect(throws: SkillDraftError.self) {
            try await service.createDraft(SkillDraftRequest(instruction: "No target", targets: []))
        }
        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test func rejectsProtectedAndSymbolicLinkStagingRootsWithoutChangingThem() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.valid(name: "unused"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let permissionsBefore = try #require(
            (FileManager.default.attributesOfItem(atPath: home.path(percentEncoded: false))[.posixPermissions] as? NSNumber)?
                .intValue
        )
        let protectedService = SkillDraftService(
            stagingRootURL: home,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        await #expect(throws: SkillDraftError.self) {
            try await protectedService.createDraft(SkillDraftRequest(instruction: "Do not write here."))
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
        let linkedService = SkillDraftService(
            stagingRootURL: linked,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )
        await #expect(throws: SkillDraftError.self) {
            try await linkedService.createDraft(SkillDraftRequest(instruction: "Do not follow this link."))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path(percentEncoded: false)).isEmpty)
    }

    @Test func reportsRedactedCodexFailureAndCleansStagingRequest() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.failure)
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        do {
            _ = try await service.createDraft(SkillDraftRequest(instruction: "Create a release skill."))
            Issue.record("Expected Codex to fail")
        } catch let error as SkillDraftError {
            #expect(error.localizedDescription.contains("Bearer [redacted]"))
            #expect(!error.localizedDescription.contains("secret-token-value"))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    @Test func reportsClearErrorWhenCodexExitsSuccessfullyWithoutADraft() async throws {
        let fixture = try makeFixture()
        let runner = SkillDraftRunnerStub(.successWithoutDraft)
        let service = SkillDraftService(
            stagingRootURL: fixture.staging,
            runner: runner,
            skillCreatorURL: fixture.skillCreator,
            homeURL: fixture.root
        )

        do {
            _ = try await service.createDraft(SkillDraftRequest(instruction: "Create a release skill."))
            Issue.record("Expected the missing draft to be reported")
        } catch let error as SkillDraftError {
            guard case .missingPackage = error else {
                Issue.record("Expected missingPackage, got \(error)")
                return
            }
            #expect(error.localizedDescription == "Codex did not create a draft package.")
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path(percentEncoded: false))
        #expect(remaining.isEmpty)
    }

    /// Amazon Toolbox installs `claude` as a link to one dispatcher that works
    /// out which tool to be from the name it was launched by. Launching the
    /// resolved target would hand it its own name and nothing to dispatch.
    @Test func processRunnerLaunchesAShimByItsInstalledNameNotItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ProcessRunnerShimTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let dispatcher = root.appending(path: "toolbox/toolbox-exec", directoryHint: .notDirectory)
        let shim = bin.appending(path: "claude", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dispatcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s' \"$0\"\n".write(to: dispatcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dispatcher.path(percentEncoded: false))
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: dispatcher)

        let launched = ProcessCommandRunner.launchExecutableURL(
            for: "claude", environment: ["PATH": bin.path(percentEncoded: false)], currentDirectory: nil)
        #expect(launched?.path(percentEncoded: false) == shim.path(percentEncoded: false))

        let output = try await ProcessCommandRunner(timeout: .seconds(3)).run(
            executable: shim.path(percentEncoded: false), arguments: [], currentDirectory: nil)
        #expect(output.status == 0)
        #expect(output.standardOutput.hasSuffix("/bin/claude"), "the shim was launched as \(output.standardOutput)")
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

    @Test func processRunnerBuildsASecretFreeEnvironmentAndIgnoresParentPath() {
        let environment = ProcessCommandRunner.childEnvironment(
            inheriting: [
                "PATH": "/tmp/attacker-first:/usr/bin",
                "OPENAI_API_KEY": "must-not-cross",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "GIT_SSH_COMMAND": "malicious-wrapper",
                "HTTPS_PROXY": "https://name:secret@example.invalid",
                "USER": "fixture-user",
                "LOGNAME": "fixture-user",
                "LANG": "en_GB.UTF-8",
                "NO_COLOR": "",
            ],
            homeURL: URL(filePath: "/Users/fixture", directoryHint: .isDirectory),
            temporaryDirectory: URL(filePath: "/tmp/safe", directoryHint: .isDirectory)
        )

        #expect(environment["HOME"] == "/Users/fixture")
        #expect(environment["USER"] == "fixture-user")
        #expect(environment["LANG"] == "en_GB.UTF-8")
        #expect(environment["NO_COLOR"] == "1")
        #expect(environment["PATH"]?.hasPrefix("/Users/fixture/.local/bin:") == true)
        #expect(environment["PATH"]?.contains("/tmp/attacker-first") == false)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(environment["GIT_SSH_COMMAND"] == nil)
        #expect(environment["HTTPS_PROXY"] == nil)
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

    /// A scratch home. The staging root sits inside it, because the policy
    /// admits a Codex start only for a request folder under the home
    /// directory; Codex's system skill and Claude's installed-plugins record
    /// are written where each client keeps them.
    private func makeFixture(claudeHasSkillCreator: Bool = true) throws -> (root: URL, staging: URL, skillCreator: URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SkillDraftServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let skillCreator = root.appending(path: "codex/skills/.system/skill-creator/SKILL.md")
        try FileManager.default.createDirectory(at: skillCreator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: skill-creator\ndescription: Create a skill.\n---\n".write(
            to: skillCreator,
            atomically: true,
            encoding: .utf8
        )
        let plugins = root.appending(path: ".claude/plugins", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let installed = claudeHasSkillCreator
            ? #"{"version":2,"plugins":{"skill-creator@claude-plugins-official":[{"scope":"user","version":"1.0.0"}]}}"#
            : #"{"version":2,"plugins":{}}"#
        try installed.write(to: plugins.appending(path: "installed_plugins.json"), atomically: true, encoding: .utf8)
        try #"{"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins-official"}}}"#
            .write(to: plugins.appending(path: "known_marketplaces.json"), atomically: true, encoding: .utf8)
        return (root, staging, skillCreator)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
