import Foundation
import Testing

@testable import AgentToolingCore

/// The model pass over an audit: what the client may do while it reads, how
/// its answer is held to the app's types, and that a claim keeps its source.
@Suite("Setup review")
struct SetupReviewTests {
    private let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    private var audit: SetupAuditReport {
        SetupAuditReport(
            clients: [.claude, .codex],
            findings: [
                SetupFinding(
                    kind: .unmanagedSkill, severity: .info, client: .claude, subject: "docx", title: "docx is not managed",
                    detail: "d", evidence: ["~/.claude/skills/docx"],
                    actions: [
                        .adoptSkill(path: "/Users/example/.claude/skills/docx", client: .claude),
                        .removeSkillCopy(path: "/Users/example/.claude/skills/docx", client: .claude),
                    ]),
                SetupFinding(
                    kind: .brokenSkillLink, severity: .medium, client: .claude, subject: "gone", title: "gone points at nothing",
                    detail: "d", evidence: ["~/.claude/skills/gone"],
                    actions: [.removeBrokenLink(path: "/Users/example/.claude/skills/gone", client: .claude)]),
            ],
            counts: [.claude: .init(skills: 2, plugins: 0, mcpServers: 0)])
    }

    // MARK: Shapes and policy

    @Test func theClaudeShapesReadOnlyTheToolingFoldersAndReachTheWebOnlyForAReview() throws {
        let local = SetupReviewCommandShapes.claude(homeURL: home, web: false)
        let web = SetupReviewCommandShapes.claude(homeURL: home, web: true)
        #expect(local.contains("Read(//Users/example/.claude/**)"))
        #expect(local.contains("Read(//Users/example/.kiro/**)"))
        #expect(!local.contains { $0.hasPrefix("Read(") && !$0.contains("/Users/example/.") }, "a Read outside the tooling folders")
        // Bash and the writers are disallowed in both; the web only in the review.
        for shape in [local, web] {
            let disallowedStart = try #require(shape.firstIndex(of: "--disallowedTools"))
            let disallowed = Array(shape[(disallowedStart + 1)...])
            #expect(
                disallowed.contains("Bash") && disallowed.contains("Edit") && disallowed.contains("Write") && disallowed.contains("Task"))
            #expect(shape.contains("--permission-mode") && shape.contains("plan"))
        }
        let localAllowedStart = try #require(local.firstIndex(of: "--allowedTools"))
        let localDisallowedStart = try #require(local.firstIndex(of: "--disallowedTools"))
        let localAllowed = local[(localAllowedStart + 1)..<localDisallowedStart]
        #expect(!localAllowed.contains("WebSearch") && local.contains("WebSearch"), "the web is disallowed locally")
        let webAllowedStart = try #require(web.firstIndex(of: "--allowedTools"))
        let webDisallowedStart = try #require(web.firstIndex(of: "--disallowedTools"))
        let webAllowed = web[(webAllowedStart + 1)..<webDisallowedStart]
        #expect(webAllowed.contains("WebSearch") && webAllowed.contains("WebFetch(domain:docs.claude.com)"))
        #expect(!webAllowed.contains("WebFetch"), "a fetch reaches the apps' documentation only")
    }

    @Test func thePolicyAdmitsExactlyTheFourShapesAndRefusesNearMisses() throws {
        let policy = OperationCommandPolicy(
            libraryURL: home.appending(path: "library"), gitBackupRoot: home.appending(path: "backup"), homeURL: home)
        let request = home.appending(
            path: "Library/Application Support/Agent Tooling/cache/setup-review/request-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)
        #expect(throws: Never.self) {
            try policy.validate(executable: "claude", arguments: SetupReviewCommandShapes.claude(homeURL: home, web: false))
            try policy.validate(executable: "claude", arguments: SetupReviewCommandShapes.claude(homeURL: home, web: true))
            try policy.validate(
                executable: "codex", arguments: SetupReviewCommandShapes.codex(homeURL: home, requestDirectory: request, web: false))
            try policy.validate(
                executable: "codex", arguments: SetupReviewCommandShapes.codex(homeURL: home, requestDirectory: request, web: true))
        }
        // Widen the read to the whole home: refused.
        var wide = SetupReviewCommandShapes.claude(homeURL: home, web: false)
        wide[try #require(wide.firstIndex(of: "Read(//Users/example/.claude/**)"))] = "Read(//Users/example/**)"
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: wide) }
        // Allow Bash: refused.
        var shell = SetupReviewCommandShapes.claude(homeURL: home, web: false)
        shell.insert("Bash", at: try #require(shell.firstIndex(of: "--disallowedTools")))
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: shell) }
        // Another person's home: refused.
        #expect(throws: OperationEngineError.self) {
            try policy.validate(
                executable: "claude", arguments: SetupReviewCommandShapes.claude(homeURL: URL(filePath: "/Users/other"), web: false))
        }
        // Codex allowed to write, or rooted somewhere else: refused.
        var writable = SetupReviewCommandShapes.codex(homeURL: home, requestDirectory: request, web: false)
        writable[try #require(writable.firstIndex(of: "read-only"))] = "workspace-write"
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "codex", arguments: writable) }
        var elsewhere = SetupReviewCommandShapes.codex(homeURL: home, requestDirectory: request, web: false)
        elsewhere[try #require(elsewhere.firstIndex(of: "--cd")) + 1] = "/"
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "codex", arguments: elsewhere) }
        #expect(throws: OperationEngineError.self) {
            try policy.validate(
                executable: "codex",
                arguments: SetupReviewCommandShapes.codex(
                    homeURL: home, requestDirectory: URL(filePath: "/tmp/request-\(UUID().uuidString.lowercased())"), web: false))
        }
    }

    @Test func theSchemaBoundsEveryStringAndParsesBack() throws {
        let data = Data(SetupReviewCommandShapes.responseSchemaJSON.utf8)
        let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let items = try #require((properties["recommendations"] as? [String: Any])?["items"] as? [String: Any])
        for (name, value) in try #require(items["properties"] as? [String: Any]) {
            guard let field = value as? [String: Any], field["type"] as? String == "string" else { continue }
            #expect(field["maxLength"] != nil || field["enum"] != nil, "\(name) is unbounded")
        }
    }

    // MARK: The prompt

    @Test func thePromptCarriesTheFindingsWithTheirIdsAndActionsAndSaysWhatTheRunIsFor() {
        let checkup = SetupReviewPrompt.render(
            purpose: .checkup, audit: audit, digests: [], focus: nil, clientVersions: [.claude: "2.1.285"])
        #expect(checkup.contains("routine check"))
        #expect(checkup.contains(audit.findings[0].id))
        #expect(checkup.contains("action[0]: Remove the broken link"), "the offered actions are listed by index")
        #expect(checkup.contains("- Claude Code: 2.1.285"))

        let review = SetupReviewPrompt.render(
            purpose: .clientReview, audit: audit, digests: [], focus: .claude, clientVersions: [.claude: "2.1.285"],
            releaseNotes: ["## Claude Code 2.1.290\n- Added X"])
        #expect(review.contains("review of Claude Code alone"))
        #expect(review.contains("Its installed version is 2.1.285"))
        #expect(review.contains("- Added X"))
    }

    // MARK: The answer

    @Test func anAnswerBecomesTypedRecommendationsAndOnlyRealActionsSurvive() throws {
        let broken = try #require(audit.findings.first { $0.kind == .brokenSkillLink })
        let unmanaged = try #require(audit.findings.first { $0.kind == .unmanagedSkill })
        let answer: [String: Any] = [
            "summary": "Two things need attention.",
            "recommendations": [
                [
                    "category": "cleanup", "title": "Remove the dead link", "summary": "s", "rationale": "r", "client": "claude",
                    "priority": 1,
                    "finding_ids": [broken.id, "not-a-finding"],
                    "provenance": ["kind": "audit", "finding_id": broken.id],
                    "action": ["kind": "take_finding_action", "finding_id": broken.id, "action_index": 0],
                ],
                [
                    "category": "unmanaged", "title": "Bring docx into the library", "summary": "s", "rationale": "r", "priority": 5,
                    "provenance": ["kind": "investigated", "source": "/Users/example/.claude/skills/docx/SKILL.md"],
                    "action": ["kind": "take_finding_action", "finding_id": unmanaged.id, "action_index": 0],
                ],
                [
                    "category": "settings", "title": "Turn on X", "summary": "s", "rationale": "r", "client": "codex", "priority": 20,
                    "provenance": ["kind": "opinion"],
                    "action": ["kind": "set_setting", "client": "codex", "key": "model_reasoning_effort", "value": "high"],
                ],
                // Names an action index the finding does not have: dropped.
                [
                    "category": "cleanup", "title": "Nonsense", "summary": "s", "rationale": "r", "priority": 2,
                    "provenance": ["kind": "opinion"],
                    "action": ["kind": "take_finding_action", "finding_id": broken.id, "action_index": 7],
                ],
                // Cites a finding that does not exist as provenance: dropped.
                [
                    "category": "cleanup", "title": "Invented", "summary": "s", "rationale": "r", "priority": 3,
                    "provenance": ["kind": "audit", "finding_id": "deadbeef"], "action": ["kind": "read_only"],
                ],
                // A plugin id with shell characters: dropped.
                [
                    "category": "additions", "title": "Install evil", "summary": "s", "rationale": "r", "priority": 4,
                    "provenance": ["kind": "opinion"],
                    "action": ["kind": "install_plugin", "client": "claude", "plugin_id": "x; rm -rf /"],
                ],
            ],
        ]
        let review = SetupReviewService.review(from: answer, client: .claude, audit: audit)
        #expect(review.summary == "Two things need attention.")
        #expect(review.recommendations.count == 3)
        #expect(review.recommendations.map(\.priority) == [1, 5, 20], "sorted by priority")
        let first = review.recommendations[0]
        #expect(first.action == .take(.removeBrokenLink(path: "/Users/example/.claude/skills/gone", client: .claude)))
        #expect(first.provenance == .audit(findingID: broken.id))
        #expect(first.findingIDs == [broken.id], "an unknown finding id is dropped from the list")
        #expect(review.recommendations[1].provenance == .investigated(source: "/Users/example/.claude/skills/docx/SKILL.md"))
        #expect(review.recommendations[1].action == .take(.adoptSkill(path: "/Users/example/.claude/skills/docx", client: .claude)))
        #expect(review.recommendations[2].action == .setSetting(client: .codex, key: "model_reasoning_effort", value: "high"))
        #expect(review.recommendations[2].provenance == .opinion)
    }

    @Test func anOverLongAnswerIsBounded() {
        let answer: [String: Any] = [
            "summary": String(repeating: "a", count: 5_000),
            "recommendations": (0..<80).map { i in
                [
                    "category": "cleanup", "title": String(repeating: "t", count: 500), "summary": "s", "rationale": "r", "priority": i,
                    "provenance": ["kind": "opinion"], "action": ["kind": "read_only"],
                ] as [String: Any]
            },
        ]
        let review = SetupReviewService.review(from: answer, client: .codex, audit: audit)
        #expect(review.summary.count == 800)
        #expect(review.recommendations.count == 40)
        #expect(review.recommendations.allSatisfy { $0.title.count <= 120 && $0.priority >= 1 })
    }

    @Test func theServiceRunsTheLocatedToolWithThePromptOnStandardInput() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appending(path: ".local/bin/codex")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        let events = """
            {"type":"thread.started","thread_id":"t"}
            {"type":"item.completed","item":{"id":"b","type":"agent_message","text":"{\\"summary\\":\\"Fine.\\",\\"recommendations\\":[]}"}}
            {"type":"turn.completed","usage":{}}

            """
        let runner = RecordingRunner(output: .init(status: 0, standardOutput: events, standardError: ""))
        let staging = root.appending(path: "Library/Caches/staging", directoryHint: .isDirectory)
        let service = SetupReviewService(stagingRootURL: staging, homeURL: root, runner: runner)

        let review = try await service.run(
            client: .codex, purpose: .checkup, audit: audit, digests: [], focus: nil, clientVersions: [.codex: "0.159"])

        #expect(review.summary == "Fine.")
        let call = try #require(await runner.calls.first)
        #expect(call.executable == tool.path(percentEncoded: false))
        #expect(call.arguments.contains("--sandbox") && call.arguments.contains("read-only"))
        #expect(!call.arguments.contains("--search"), "a checkup does not reach the web")
        #expect(String(decoding: call.standardInput, as: UTF8.self).contains("routine check"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false)).isEmpty,
            "the request folder is put away")
    }

    private actor RecordingRunner: StandardInputCommandRunning {
        struct Call {
            let executable: String
            let arguments: [String]
            let standardInput: Data
        }
        private let output: CommandOutput
        private(set) var calls: [Call] = []
        init(output: CommandOutput) { self.output = output }
        func run(executable: String, arguments: [String], standardInput: Data, currentDirectory: URL?) async throws -> CommandOutput {
            calls.append(Call(executable: executable, arguments: arguments, standardInput: standardInput))
            return output
        }
    }
}
