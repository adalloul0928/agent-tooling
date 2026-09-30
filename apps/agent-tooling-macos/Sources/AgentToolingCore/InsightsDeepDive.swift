import CryptoKit
import Foundation

// MARK: - What the deep dive produces

/// What the deep dive concluded, kept beside the report.
///
/// The recommendations it holds are the same shape the keyword pass produces,
/// so the Insights screen shows them the same way; `themes` are the model's own
/// reading of what the person keeps doing, which the keyword pass cannot
/// produce at all. Nothing here is a conversation excerpt: the model was asked
/// for conclusions, not quotes, and the parser drops anything long enough to be
/// one.
public struct InsightsDeepDive: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var client: ClientKind
    public var conversationsConsidered: Int
    public var windowStart: Date
    public var themes: [DeepDiveTheme]
    public var recommendations: [ToolRecommendation]
    /// The model's one-paragraph read of the period, for the top of the screen.
    public var summary: String

    public init(
        generatedAt: Date = .now, client: ClientKind, conversationsConsidered: Int, windowStart: Date,
        themes: [DeepDiveTheme], recommendations: [ToolRecommendation], summary: String
    ) {
        self.generatedAt = generatedAt
        self.client = client
        self.conversationsConsidered = conversationsConsidered
        self.windowStart = windowStart
        self.themes = themes
        self.recommendations = recommendations
        self.summary = summary
    }
}

/// One recurring kind of work the model saw.
public struct DeepDiveTheme: Codable, Hashable, Identifiable, Sendable {
    public var id: String { title }
    public var title: String
    public var detail: String
    public var conversationCount: Int
    /// Which apps the pattern showed up in.
    public var clients: [ClientKind]

    public init(title: String, detail: String, conversationCount: Int, clients: [ClientKind]) {
        self.title = title
        self.detail = detail
        self.conversationCount = conversationCount
        self.clients = clients
    }
}

// MARK: - The command shapes

/// How each client is asked to read the digests and answer with one JSON
/// document, in one place so the adapters that build the argument lists and
/// the policy that admits them cannot drift apart.
///
/// The digests travel on standard input. The answer's shape is pinned by a JSON
/// schema: Claude takes it on the command line, Codex reads it from a file the
/// service writes beside the prompt inside the staged folder, so the argument
/// list itself stays fixed.
public enum InsightsDeepDiveCommandShapes {
    /// The name of the schema file written into the request folder for Codex.
    public static let codexSchemaFileName = "deep-dive-schema.json"

    /// Claude Code in print mode with no tools at all: it may read the prompt
    /// and answer, and nothing else. No session is kept.
    public static func claude() -> [String] {
        [
            "-p", "--output-format", "json",
            "--json-schema", responseSchemaJSON,
            "--permission-mode", "plan",
            "--strict-mcp-config",
            "--setting-sources", "user",
            "--disallowedTools", "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch", "Task", "Read", "Glob", "Grep",
        ]
    }

    /// Codex in exec mode, read-only, ephemeral, inside the staged request
    /// folder that holds the schema file. Plugins, hooks, and apps are off.
    public static func codex(requestDirectory: URL) -> [String] {
        [
            "exec", "--json", "--ephemeral",
            "--ignore-rules",
            "--disable", "plugins", "--disable", "hooks", "--disable", "apps", "--disable", "remote_plugin",
            "--sandbox", "read-only",
            "--skip-git-repo-check", "--color", "never",
            "--cd", requestDirectory.path(percentEncoded: false),
            "--output-schema", requestDirectory.appending(path: codexSchemaFileName).path(percentEncoded: false),
            "-",
        ]
    }

    public static func isClaudeShape(_ arguments: [String]) -> Bool {
        arguments == claude()
    }

    /// The Codex shape, for the policy: the folder must be a request folder
    /// under the home directory, and the schema file must be inside it.
    public static func isCodexShape(_ arguments: [String], homeURL: URL) -> Bool {
        guard let index = arguments.firstIndex(of: "--cd"), arguments.indices.contains(index + 1) else { return false }
        let path = arguments[index + 1]
        guard SkillCreatorCommandShapes.isRequestDirectoryPath(path, homeURL: homeURL) else { return false }
        return arguments == codex(requestDirectory: URL(filePath: path, directoryHint: .isDirectory))
    }

    /// The shape of the answer both clients are held to. Every string is
    /// bounded, so the model cannot answer with a transcript. Built on each
    /// call: a `[String: Any]` cannot be a shared constant under strict
    /// concurrency, and the JSON string below is what callers actually use.
    public static var responseSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "themes", "recommendations"],
        "properties": [
            "summary": ["type": "string", "maxLength": 600],
            "themes": [
                "type": "array", "maxItems": 8,
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["title", "detail", "conversation_count", "clients"],
                    "properties": [
                        "title": ["type": "string", "maxLength": 80],
                        "detail": ["type": "string", "maxLength": 400],
                        "conversation_count": ["type": "integer", "minimum": 1],
                        "clients": ["type": "array", "items": ["type": "string", "enum": ["claude", "codex", "kiro"]]],
                    ],
                ],
            ],
            "recommendations": [
                "type": "array", "maxItems": 10,
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["kind", "title", "summary", "rationale", "confidence", "conversation_count"],
                    "properties": [
                        "kind": ["type": "string", "enum": ["create_skill", "use_existing_skill", "improve_skill"]],
                        "title": ["type": "string", "maxLength": 80],
                        "summary": ["type": "string", "maxLength": 300],
                        "rationale": ["type": "string", "maxLength": 400],
                        "confidence": ["type": "string", "enum": ["high", "medium", "exploratory"]],
                        "conversation_count": ["type": "integer", "minimum": 1],
                        "existing_skill": ["type": "string", "maxLength": 128],
                        "draft_instruction": ["type": "string", "maxLength": 1500],
                    ],
                ],
            ],
        ],
    ] }

    public static var responseSchemaJSON: String {
        let data = try! JSONSerialization.data(withJSONObject: responseSchema, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The prompt

enum InsightsDeepDivePrompt {
    static let maximumDigests = 120
    static let maximumPromptBytes = 180 * 1_024

    /// The whole prompt: the task, the skills the person already has, and the
    /// digests. Digests are added newest first until the byte budget is spent,
    /// so a heavy month is summarized from its most recent work rather than
    /// refused.
    static func render(digests: [ConversationDigest], skills: [Skill], windowStart: Date, now: Date) -> (prompt: String, used: Int) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var header = """
            You are reviewing how one person has been using their AI coding assistants over the last \(max(1, Int(now.timeIntervalSince(windowStart) / 86_400))) days, to find work they keep doing by hand that a reusable Agent Skill would capture, skills they already have but are not using when they should, and skills that should be improved.

            An Agent Skill is a SKILL.md file with instructions the assistant loads when a task matches its description. The person uses Claude Code, Codex, and Kiro CLI. Below are digests of their recent conversations: the first few things they asked (redacted), the tools and skills that answered, and the project. Read them as evidence of real, repeated needs. Do not invent work that is not there, do not quote the digests back, and prefer fewer, well-grounded conclusions over many weak ones. Every recommendation must be supported by at least two conversations. Some digests are probes rather than work — one-word tests, "ping", "whoami", "say pong", dry runs of a tool — and should be ignored entirely, not counted or mentioned. For a create_skill recommendation, write draft_instruction as the brief a skill author would need: what the skill does, when it should trigger, what it should produce, and constraints. For use_existing_skill or improve_skill, set existing_skill to the skill's name exactly as listed below.

            Answer only with the JSON the schema describes.

            ## Skills the person already has (name — description)

            """
        let skillLines = skills
            .sorted { $0.id < $1.id }
            .prefix(400)
            .map { skill -> String in
                let description = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return "- \(skill.id)" + (description.isEmpty ? "" : " — \(String(description.prefix(160)))")
            }
        header += skillLines.joined(separator: "\n") + "\n\n## Conversations (newest first)\n\n"

        var body = ""
        var used = 0
        for digest in digests.sorted(by: { $0.endedAt > $1.endedAt }).prefix(maximumDigests) {
            var entry = "### \(digest.client.rawValue) · \(formatter.string(from: digest.startedAt))"
            if let directory = digest.workingDirectory { entry += " · project: \(directory)" }
            if let title = digest.title, !title.isEmpty { entry += "\ntitle: \(title)" }
            entry += "\nmessages from the person: \(digest.userMessageCount)"
            if !digest.skillsUsed.isEmpty { entry += "\nskills invoked: \(digest.skillsUsed.joined(separator: ", "))" }
            if !digest.toolsUsed.isEmpty { entry += "\ntools used: \(digest.toolsUsed.joined(separator: ", "))" }
            for (index, message) in digest.userMessages.enumerated() {
                let label = index == 0 ? "first ask" : "later"
                entry += "\n\(label): \(message.replacingOccurrences(of: "\n", with: " "))"
            }
            entry += "\n\n"
            guard header.utf8.count + body.utf8.count + entry.utf8.count <= maximumPromptBytes else { break }
            body += entry
            used += 1
        }
        return (header + body, used)
    }
}

// MARK: - Running it

public enum InsightsDeepDiveError: LocalizedError, Equatable, Sendable {
    case unsupportedClient(ClientKind)
    case nothingToRead
    case commandRefused(ClientKind)
    case clientFailed(ClientKind, Int32, String)
    case unreadableAnswer(ClientKind)

    public var errorDescription: String? {
        switch self {
        case .unsupportedClient(let client): "\(client.rawValue) cannot run the deep dive."
        case .nothingToRead: "No recent conversations were found to read."
        case .commandRefused(let client):
            "Agent Tooling did not recognise the command it was about to run for \(client.rawValue) and refused to run it."
        case .clientFailed(let client, let status, let diagnostic):
            "\(client.rawValue) could not finish the deep dive (status \(status)): \(diagnostic)"
        case .unreadableAnswer(let client): "\(client.rawValue) answered, but not in the shape the deep dive asked for."
        }
    }
}

/// Asks the person's own assistant to read the digests and say what it sees.
///
/// One command per run, checked by the operation policy, prompt on standard
/// input, answer as one JSON document held to a schema. The staged folder
/// exists only so Codex has somewhere to read its schema file from and to run
/// read-only in; it is removed when the run ends.
public struct InsightsDeepDiveService: Sendable {
    private let runner: any StandardInputCommandRunning
    private let stagingRootURL: URL
    private let homeURL: URL
    private let policy: OperationCommandPolicy

    public init(
        stagingRootURL: URL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: any StandardInputCommandRunning = ProcessCommandRunner(timeout: .seconds(900))
    ) {
        self.stagingRootURL = stagingRootURL
        self.homeURL = homeURL
        self.runner = runner
        self.policy = OperationCommandPolicy(
            libraryURL: homeURL.appending(path: ".agent-tooling/library", directoryHint: .isDirectory),
            gitBackupRoot: homeURL.appending(path: ".agent-tooling/git-backup", directoryHint: .isDirectory),
            homeURL: homeURL)
    }

    public func run(
        client: ClientKind, digests: [ConversationDigest], skills: [Skill], windowStart: Date, now: Date = .now
    ) async throws -> InsightsDeepDive {
        guard client == .claude || client == .codex else { throw InsightsDeepDiveError.unsupportedClient(client) }
        guard !digests.isEmpty else { throw InsightsDeepDiveError.nothingToRead }
        let rendered = InsightsDeepDivePrompt.render(digests: digests, skills: skills, windowStart: windowStart, now: now)

        let requestURL = stagingRootURL.appending(path: "request-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: requestURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: requestURL) }

        let executable = ClientExecutableLocator.locate(client, homeURL: homeURL)?.path(percentEncoded: false)
            ?? ClientExecutableLocator.executableName(for: client)
        let arguments: [String]
        switch client {
        case .claude:
            arguments = InsightsDeepDiveCommandShapes.claude()
        case .codex:
            try Data(InsightsDeepDiveCommandShapes.responseSchemaJSON.utf8).write(
                to: requestURL.appending(path: InsightsDeepDiveCommandShapes.codexSchemaFileName), options: .atomic)
            arguments = InsightsDeepDiveCommandShapes.codex(requestDirectory: requestURL)
        default:
            throw InsightsDeepDiveError.unsupportedClient(client)
        }
        do {
            try policy.validate(executable: executable, arguments: arguments)
        } catch {
            throw InsightsDeepDiveError.commandRefused(client)
        }

        let output = try await runner.run(
            executable: executable, arguments: arguments, standardInput: Data(rendered.prompt.utf8), currentDirectory: requestURL)
        let answer: [String: Any]
        switch client {
        case .claude:
            answer = try Self.parseClaude(output, client: client)
        default:
            answer = try Self.parseCodex(output, client: client)
        }
        // Stamped when the answer arrived, not when the ask went out: the daily
        // run measures its age from this.
        return try Self.deepDive(from: answer, client: client, considered: rendered.used, windowStart: windowStart, now: .now)
    }

    // MARK: Parsing

    /// Claude's `result` document. With `--json-schema` the answer is in
    /// `structured_output`; without it, `result` holds the text.
    static func parseClaude(_ output: CommandOutput, client: ClientKind) throws -> [String: Any] {
        guard let start = output.standardOutput.firstIndex(of: "{"),
            let document = try? JSONSerialization.jsonObject(with: Data(output.standardOutput[start...].utf8)) as? [String: Any]
        else {
            throw InsightsDeepDiveError.clientFailed(client, output.status, Self.diagnostic(output))
        }
        if (document["is_error"] as? Bool) == true {
            throw InsightsDeepDiveError.clientFailed(client, output.status, Self.diagnostic(output, fallback: document["result"] as? String))
        }
        if let structured = document["structured_output"] as? [String: Any] { return structured }
        if let text = document["result"] as? String, let parsed = Self.firstJSONObject(in: text) { return parsed }
        throw InsightsDeepDiveError.unreadableAnswer(client)
    }

    /// Codex's event stream: the last `agent_message` item is the answer.
    static func parseCodex(_ output: CommandOutput, client: ClientKind) throws -> [String: Any] {
        var last: String?
        var failure: String?
        for line in output.standardOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let type = event["type"] as? String
            else { continue }
            if type == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                last = item["text"] as? String
            } else if type == "turn.failed" {
                failure = (event["error"] as? [String: Any])?["message"] as? String ?? "The turn failed."
            }
        }
        if let failure { throw InsightsDeepDiveError.clientFailed(client, output.status, Self.diagnostic(output, fallback: failure)) }
        guard let last, let parsed = Self.firstJSONObject(in: last) else {
            if output.status != 0 { throw InsightsDeepDiveError.clientFailed(client, output.status, Self.diagnostic(output)) }
            throw InsightsDeepDiveError.unreadableAnswer(client)
        }
        return parsed
    }

    static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }

    private static func diagnostic(_ output: CommandOutput, fallback: String? = nil) -> String {
        let raw = [fallback ?? "", output.standardError, output.standardOutput].first { !$0.isEmpty } ?? ""
        let redacted = SensitiveValueRedactor.redact(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((redacted.isEmpty ? "No diagnostic." : redacted).prefix(2_048))
    }

    /// The model's answer as this app's own types. Anything the schema would
    /// have refused is dropped here too, so an answer from a client that did
    /// not honour the schema is bounded all the same.
    static func deepDive(
        from answer: [String: Any], client: ClientKind, considered: Int, windowStart: Date, now: Date
    ) throws -> InsightsDeepDive {
        func bounded(_ value: Any?, _ maximum: Int) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(maximum))
        }
        func clientKind(_ value: Any?) -> ClientKind? {
            switch (value as? String)?.lowercased() {
            case "claude", "claude-code", "claude code": .claude
            case "codex": .codex
            case "kiro", "kiro-cli", "kiro cli": .kiro
            default: nil
            }
        }
        let themes = ((answer["themes"] as? [[String: Any]]) ?? []).prefix(8).compactMap { theme -> DeepDiveTheme? in
            guard let title = bounded(theme["title"], 80), let detail = bounded(theme["detail"], 400) else { return nil }
            return DeepDiveTheme(
                title: title, detail: detail,
                conversationCount: max(1, (theme["conversation_count"] as? Int) ?? 1),
                clients: ((theme["clients"] as? [Any]) ?? []).compactMap(clientKind))
        }
        let recommendations = ((answer["recommendations"] as? [[String: Any]]) ?? []).prefix(10).enumerated()
            .compactMap { index, item -> ToolRecommendation? in
                guard let title = bounded(item["title"], 80), let summary = bounded(item["summary"], 300),
                    let rationale = bounded(item["rationale"], 400)
                else { return nil }
                let kind: ToolRecommendationKind
                switch item["kind"] as? String {
                case "create_skill": kind = .createCustomSkill
                case "use_existing_skill", "improve_skill": kind = .useExistingSkill
                default: return nil
                }
                let confidence: RecommendationConfidence
                switch item["confidence"] as? String {
                case "high": confidence = .high
                case "medium": confidence = .medium
                default: confidence = .exploratory
                }
                let count = max(1, (item["conversation_count"] as? Int) ?? 1)
                let existing = bounded(item["existing_skill"], 128)
                return ToolRecommendation(
                    id: "deep-dive:\(client.rawValue.lowercased()):\(index):\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    kind: kind, title: title, summary: summary,
                    rationale: (item["kind"] as? String == "improve_skill" ? "Improve: " : "") + rationale,
                    confidence: confidence, supportingConversationCount: count,
                    skillID: existing, sourceName: "\(client.rawValue) deep dive",
                    draftInstruction: kind == .createCustomSkill ? bounded(item["draft_instruction"], 1_500) : nil)
            }
        guard let summary = bounded(answer["summary"], 600) else { throw InsightsDeepDiveError.unreadableAnswer(client) }
        return InsightsDeepDive(
            generatedAt: now, client: client, conversationsConsidered: considered, windowStart: windowStart,
            themes: Array(themes), recommendations: Array(recommendations), summary: summary)
    }
}
