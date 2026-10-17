import Foundation
import Testing

@testable import AgentToolingCore

/// The deep dive: what is sent to the person's own assistant, how the command
/// that sends it is held to one shape, and how the answer is read back.
@Suite("Insights deep dive")
struct InsightsDeepDiveTests {
    // MARK: - Digests

    @Test func aDigestKeepsTheFirstAsksTheToolsAndTheProjectNameAndNothingSecret() {
        var builder = ConversationDigestBuilder(conversationID: "c1", client: .claude)
        builder.workingDirectory = "/Users/example/ws/WootOrderHistory"
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        builder.noteUserMessage("Fix the failing brazil build in /Users/example/ws/WootOrderHistory, token=sk-live-abcdef123456789", at: start)
        builder.noteTool("Bash", at: start.addingTimeInterval(10))
        builder.noteTool("Bash", at: start.addingTimeInterval(20))
        builder.noteTool("Skill", at: start.addingTimeInterval(30))
        builder.noteSkill("brazil", at: start.addingTimeInterval(30))
        for index in 0..<6 {
            builder.noteUserMessage("follow-up \(index)", at: start.addingTimeInterval(Double(100 + index)))
        }

        let digest = builder.digest!

        #expect(digest.client == .claude)
        #expect(digest.workingDirectory == "WootOrderHistory", "the project is named, not located")
        #expect(digest.userMessageCount == 7)
        // The first ask, then the most recent few: capped, with the middle gone.
        #expect(digest.userMessages.count == ConversationDigestBuilder.maximumUserMessages)
        #expect(digest.userMessages.first?.hasPrefix("Fix the failing brazil build in [local-path]") == true)
        #expect(digest.userMessages.last == "follow-up 5")
        #expect(!digest.userMessages.joined().contains("sk-live-abcdef123456789"), "a secret survived redaction")
        #expect(digest.toolsUsed == ["Bash", "Skill"], "tools are listed once each")
        #expect(digest.skillsUsed == ["brazil"])
        #expect(digest.startedAt == start)
        #expect(digest.endedAt == start.addingTimeInterval(105))
    }

    @Test func aConversationWithNothingToLearnFromHasNoDigest() {
        var silent = ConversationDigestBuilder(conversationID: "c2", client: .codex)
        silent.noteTool("shell", at: .now)
        #expect(silent.digest == nil, "nobody asked anything")

        var probe = ConversationDigestBuilder(conversationID: "c3", client: .claude)
        probe.noteUserMessage("say pong", at: .now)
        #expect(probe.digest == nil, "a probe is not work")

        var short = ConversationDigestBuilder(conversationID: "c4", client: .claude)
        short.noteUserMessage("run the tests", at: .now)
        short.noteTool("Bash", at: .now)
        #expect(short.digest != nil, "a short ask that reached a tool is real work")
    }

    @Test func aScanOfKiroSessionsProducesDigestsAndAttributesSlashCommands() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "InsightsDeepDiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appending(path: ".kiro/sessions/cli", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date.now
        let stamp = Int(now.timeIntervalSince1970) - 3_600
        let id = "0a0b0c0d-1111-2222-3333-444444444444"
        try #"{"session_id":"\#(id)","cwd":"/Users/example/ws/WootFeatureFlags","title":"Ship the flags","created_at":"2026-09-30T17:37:07Z"}"#
            .write(to: sessions.appending(path: "\(id).json"), atomically: true, encoding: .utf8)
        let lines = [
            #"{"version":"v1","kind":"Prompt","data":{"message_id":"m1","content":[{"kind":"text","data":"/woot-wbr run the Tech WBR for last week"}],"meta":{"timestamp":\#(stamp)}}}"#,
            #"{"version":"v1","kind":"AssistantMessage","data":{"message_id":"m2","content":[{"kind":"tool_use","data":{"name":"shell","id":"t1","args":{}}}],"meta":{"timestamp":\#(stamp + 5)}}}"#,
            #"{"version":"v1","kind":"ToolResults","data":{"message_id":"m3","content":[],"meta":{"timestamp":\#(stamp + 6)}}}"#,
            #"{"version":"v1","kind":"Prompt","data":{"message_id":"m4","content":[{"kind":"text","data":"now email it to the team"}],"meta":{"timestamp":\#(stamp + 60)}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: sessions.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8)
        let skill = Skill(
            id: "woot-wbr", name: "woot-wbr", displayName: "Woot WBR", summary: "Weekly report", bundle: "standalone",
            scope: "This Mac", owned: false, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)

        let artifact = LocalConversationScanner().scan(
            options: .init(clients: [.kiro], lookbackDays: 7), skills: [skill], homeURL: root, now: now)

        let coverage = try #require(artifact.coverage.first)
        #expect(coverage.client == .kiro)
        #expect(coverage.status == .scanned, Comment(rawValue: coverage.detail))
        #expect(coverage.conversationsScanned == 1)
        let digest = try #require(artifact.digests.first)
        #expect(digest.title == "Ship the flags")
        #expect(digest.workingDirectory == "WootFeatureFlags")
        #expect(digest.userMessages == ["/woot-wbr run the Tech WBR for last week", "now email it to the team"])
        #expect(digest.toolsUsed == ["shell"])
        #expect(digest.skillsUsed == ["woot-wbr"])
        // The slash command is exact evidence that the skill was used.
        let evidence = try #require(artifact.evidence.first)
        #expect(evidence.skillID == "woot-wbr")
        #expect(evidence.precision == .exact)
        #expect(evidence.provenance == .kiroSlashCommand)
        #expect(evidence.client == .kiro)
    }

    // MARK: - The prompt

    @Test func thePromptListsTheSkillsAndTheDigestsNewestFirstWithinItsBudget() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var digests: [ConversationDigest] = []
        for index in 0..<3 {
            let started = now.addingTimeInterval(Double(-index) * 86_400)
            digests.append(
                ConversationDigest(
                    conversationID: "c\(index)", client: .claude, startedAt: started, endedAt: started.addingTimeInterval(60),
                    title: "Title \(index)", workingDirectory: "Project\(index)", userMessages: ["ask \(index)"],
                    userMessageCount: 1, toolsUsed: ["Bash"], skillsUsed: []))
        }
        let skill = Skill(
            id: "docx", name: "docx", displayName: "Docx", summary: "Word documents", bundle: "standalone", scope: "This Mac",
            owned: false, triggers: [], negativeTrigger: "", files: [], clients: [], validationCount: 0)

        let rendered = InsightsDeepDivePrompt.render(
            digests: digests, skills: [skill], windowStart: now.addingTimeInterval(-30 * 86_400), now: now)

        #expect(rendered.used == 3)
        #expect(rendered.prompt.contains("- docx — Word documents"))
        let first = rendered.prompt.range(of: "ask 0")!.lowerBound
        let last = rendered.prompt.range(of: "ask 2")!.lowerBound
        #expect(first < last, "newest conversation comes first")
        #expect(rendered.prompt.contains("project: Project1"))
        #expect(rendered.prompt.contains("Answer only with the JSON"))
    }

    @Test func thePromptStopsAtItsByteBudgetRatherThanRefusing() {
        let now = Date.now
        let big = String(repeating: "word ", count: 80)
        var digests: [ConversationDigest] = []
        for index in 0..<400 {
            let at = now.addingTimeInterval(Double(-index))
            digests.append(
                ConversationDigest(
                    conversationID: "c\(index)", client: .codex, startedAt: at, endedAt: at, userMessages: [big, big, big, big],
                    userMessageCount: 4, toolsUsed: [], skillsUsed: []))
        }
        let rendered = InsightsDeepDivePrompt.render(digests: digests, skills: [], windowStart: now.addingTimeInterval(-86_400), now: now)
        #expect(rendered.used > 0)
        #expect(rendered.used < 400)
        #expect(rendered.prompt.utf8.count <= InsightsDeepDivePrompt.maximumPromptBytes)
    }

    // MARK: - The command and the policy

    @Test func thePolicyAdmitsExactlyTheDeepDiveShapes() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        let policy = OperationCommandPolicy(
            libraryURL: home.appending(path: "library"), gitBackupRoot: home.appending(path: "backup"), homeURL: home)
        let request = home.appending(
            path: "Library/Application Support/Agent Tooling/cache/insights-deep-dive/request-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)

        #expect(throws: Never.self) {
            try policy.validate(executable: "claude", arguments: InsightsDeepDiveCommandShapes.claude())
            try policy.validate(executable: "codex", arguments: InsightsDeepDiveCommandShapes.codex(requestDirectory: request))
        }
        // Claude may not have tools; Codex may not write; the folder must be a
        // request folder under the home directory.
        var withTools = InsightsDeepDiveCommandShapes.claude()
        withTools.removeLast(11)
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: withTools) }
        var writable = InsightsDeepDiveCommandShapes.codex(requestDirectory: request)
        writable[writable.firstIndex(of: "read-only")!] = "workspace-write"
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "codex", arguments: writable) }
        #expect(throws: OperationEngineError.self) {
            try policy.validate(
                executable: "codex",
                arguments: InsightsDeepDiveCommandShapes.codex(requestDirectory: URL(filePath: "/tmp/request-\(UUID().uuidString.lowercased())")))
        }
        #expect(!InsightsDeepDiveCommandShapes.claude().contains("--resume"), "the deep dive keeps no session")
    }

    @Test func theSchemaBoundsEveryString() throws {
        let schema = InsightsDeepDiveCommandShapes.responseSchema
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect((properties["summary"] as? [String: Any])?["maxLength"] as? Int == 600)
        let recommendations = try #require((properties["recommendations"] as? [String: Any])?["items"] as? [String: Any])
        let fields = try #require(recommendations["properties"] as? [String: Any])
        for (name, value) in fields {
            guard let field = value as? [String: Any], field["type"] as? String == "string" else { continue }
            #expect(field["maxLength"] != nil || field["enum"] != nil, "\(name) is unbounded")
        }
        // The JSON form is what goes on the command line and must parse back.
        _ = try JSONSerialization.jsonObject(with: Data(InsightsDeepDiveCommandShapes.responseSchemaJSON.utf8))
    }

    // MARK: - Reading the answer

    private static let answer = """
        {"summary":"You spend most weeks fixing Brazil builds and drafting CRs by hand.",
         "themes":[{"title":"Brazil build repair","detail":"Eleven sessions start from a failed brazil-build.","conversation_count":11,"clients":["claude","kiro"]}],
         "recommendations":[
           {"kind":"create_skill","title":"Brazil build triage","summary":"Diagnose a failed brazil-build from its log.","rationale":"Repeated across 11 sessions.","confidence":"high","conversation_count":11,"draft_instruction":"Create a skill that reads a brazil-build log and names the failing step."},
           {"kind":"use_existing_skill","title":"Use crux-code-reviews","summary":"You write CR descriptions by hand.","rationale":"Six sessions.","confidence":"medium","conversation_count":6,"existing_skill":"crux-code-reviews"},
           {"kind":"nonsense","title":"x","summary":"y","rationale":"z","confidence":"high","conversation_count":1}
         ]}
        """

    @Test func aClaudeAnswerIsReadFromItsStructuredOutput() throws {
        let document = #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"","structured_output":\#(Self.answer)}"#
        let parsed = try InsightsDeepDiveService.parseClaude(.init(status: 0, standardOutput: document, standardError: ""), client: .claude)
        let dive = try InsightsDeepDiveService.deepDive(from: parsed, client: .claude, considered: 40, windowStart: .distantPast, now: .now)

        #expect(dive.summary.hasPrefix("You spend most weeks"))
        #expect(dive.themes.count == 1)
        #expect(dive.themes[0].clients == [.claude, .kiro])
        #expect(dive.recommendations.count == 2, "an unknown kind is dropped, not guessed at")
        #expect(dive.recommendations[0].kind == .createCustomSkill)
        #expect(dive.recommendations[0].draftInstruction?.hasPrefix("Create a skill") == true)
        #expect(dive.recommendations[0].sourceName == "Claude Code deep dive")
        #expect(dive.recommendations[1].kind == .useExistingSkill)
        #expect(dive.recommendations[1].skillID == "crux-code-reviews")
        #expect(dive.conversationsConsidered == 40)
    }

    @Test func aCodexAnswerIsTheLastAgentMessage() throws {
        let events = """
            {"type":"thread.started","thread_id":"t"}
            {"type":"item.completed","item":{"id":"a","type":"agent_message","text":"Thinking..."}}
            {"type":"item.completed","item":{"id":"b","type":"agent_message","text":\(Self.answer.replacingOccurrences(of: "\n", with: " ").debugDescription)}}
            {"type":"turn.completed","usage":{}}

            """
        let parsed = try InsightsDeepDiveService.parseCodex(.init(status: 0, standardOutput: events, standardError: ""), client: .codex)
        #expect((parsed["summary"] as? String)?.hasPrefix("You spend") == true)
    }

    @Test func aFailedTurnIsReportedWithItsOwnWordsAndNoSecret() {
        let claude = #"{"type":"result","subtype":"error","is_error":true,"result":"Failed to authenticate. Bearer sk-live-abcdef1234567890"}"#
        #expect(throws: InsightsDeepDiveError.self) {
            try InsightsDeepDiveService.parseClaude(.init(status: 1, standardOutput: claude, standardError: ""), client: .claude)
        }
        do {
            _ = try InsightsDeepDiveService.parseClaude(.init(status: 1, standardOutput: claude, standardError: ""), client: .claude)
        } catch let error as InsightsDeepDiveError {
            #expect(error.localizedDescription.contains("Failed to authenticate"))
            #expect(!error.localizedDescription.contains("sk-live-abcdef1234567890"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        let codex = """
            {"type":"thread.started","thread_id":"t"}
            {"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized"}}

            """
        #expect(throws: InsightsDeepDiveError.self) {
            try InsightsDeepDiveService.parseCodex(.init(status: 1, standardOutput: codex, standardError: ""), client: .codex)
        }
    }

    @Test func anAnswerThatIgnoredTheSchemaIsBoundedAllTheSame() throws {
        let answer: [String: Any] = [
            "summary": String(repeating: "a", count: 5_000),
            "themes": (0..<20).map { ["title": "t\($0)", "detail": String(repeating: "d", count: 2_000), "conversation_count": 3, "clients": ["claude"]] },
            "recommendations": [],
        ]
        let dive = try InsightsDeepDiveService.deepDive(from: answer, client: .codex, considered: 1, windowStart: .distantPast, now: .now)
        #expect(dive.summary.count == 600)
        #expect(dive.themes.count == 8)
        #expect(dive.themes.allSatisfy { $0.detail.count <= 400 })
    }

    @Test func theServiceRunsTheLocatedToolWithThePromptOnStandardInput() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "InsightsDeepDiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        let runner = RecordingRunner(
            output: .init(
                status: 0,
                standardOutput: #"{"type":"result","is_error":false,"structured_output":\#(Self.answer)}"#, standardError: ""))
        let staging = root.appending(path: "Library/Caches/staging", directoryHint: .isDirectory)
        let service = InsightsDeepDiveService(stagingRootURL: staging, homeURL: root, runner: runner)
        let digest = ConversationDigest(
            conversationID: "c", client: .claude, startedAt: .now, endedAt: .now, userMessages: ["fix the build"],
            userMessageCount: 1, toolsUsed: ["Bash"], skillsUsed: [])

        let dive = try await service.run(client: .claude, digests: [digest], skills: [], windowStart: .now.addingTimeInterval(-86_400))

        let call = try #require(await runner.calls.first)
        #expect(call.executable == tool.path(percentEncoded: false))
        #expect(call.arguments == InsightsDeepDiveCommandShapes.claude())
        let prompt = String(decoding: call.standardInput, as: UTF8.self)
        #expect(prompt.contains("first ask: fix the build"))
        #expect(!call.arguments.contains { $0.contains("fix the build") }, "the prompt travelled on the command line")
        #expect(dive.recommendations.count == 2)
        // The staged folder is put away when the run ends.
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false)).isEmpty)
    }

    private actor RecordingRunner: StandardInputCommandRunning {
        struct Call { let executable: String; let arguments: [String]; let standardInput: Data; let currentDirectory: URL? }
        private let output: CommandOutput
        private(set) var calls: [Call] = []

        init(output: CommandOutput) { self.output = output }

        func run(executable: String, arguments: [String], standardInput: Data, currentDirectory: URL?) async throws -> CommandOutput {
            calls.append(Call(executable: executable, arguments: arguments, standardInput: standardInput, currentDirectory: currentDirectory))
            return output
        }
    }
}
