import Foundation

// MARK: - Recommendations

/// Where a recommendation's claim comes from. The screen shows this beside
/// every item, so a model's inference never dresses up as a script's fact.
public enum SetupRecommendationProvenance: Codable, Hashable, Sendable {
    /// Grounded in a deterministic finding, by id.
    case audit(findingID: String)
    /// Something the model read for itself: a file under the tooling folders,
    /// or for a client review a page on the web. The source is named.
    case investigated(source: String)
    /// The model's judgment with nothing specific behind it.
    case opinion

    public var label: String {
        switch self {
        case .audit: "From the audit"
        case .investigated(let source): "Read: \(source)"
        case .opinion: "The assistant's view"
        }
    }
}

/// What the model proposes doing. Each case is a typed request the app
/// carries out through its own reviewed paths, or an explanation with no
/// action. Free text never becomes a command.
public enum SetupRecommendationAction: Codable, Hashable, Sendable {
    /// One of the audit's own offered actions, chosen by the model.
    case take(SetupAction)
    /// Set a key in a client's settings to a value. Applied through the
    /// configuration adapter, which knows the file and validates the key.
    case setSetting(client: ClientKind, key: String, value: String)
    /// Install a plugin by its native id with the client's own command.
    case installPlugin(client: ClientKind, pluginID: String)
    /// Turn an MCP server off in a client without removing it.
    case disableMCPServer(client: ClientKind, name: String)
    /// Look at something; nothing to apply.
    case readOnly

    public var changesFiles: Bool {
        switch self {
        case .take(let action): action.changesFiles
        case .readOnly: false
        default: true
        }
    }
}

public struct SetupRecommendation: Identifiable, Codable, Hashable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case cleanup, duplicates, unmanaged, connections, settings, additions, updates
    }

    public var id: String
    public var category: Category
    public var title: String
    public var summary: String
    public var rationale: String
    public var client: ClientKind?
    public var priority: Int
    public var provenance: SetupRecommendationProvenance
    public var action: SetupRecommendationAction
    /// Finding ids this recommendation covers; a screen that takes it can
    /// mark those findings handled.
    public var findingIDs: [String]

    public init(
        id: String, category: Category, title: String, summary: String, rationale: String, client: ClientKind?, priority: Int,
        provenance: SetupRecommendationProvenance, action: SetupRecommendationAction, findingIDs: [String]
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.rationale = rationale
        self.client = client
        self.priority = priority
        self.provenance = provenance
        self.action = action
        self.findingIDs = findingIDs
    }
}

/// The model's reading of an audit: an overall picture and a prioritized list.
public struct SetupReview: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var client: ClientKind
    public var auditGeneratedAt: Date
    public var summary: String
    public var recommendations: [SetupRecommendation]

    public init(
        generatedAt: Date = .now, client: ClientKind, auditGeneratedAt: Date, summary: String, recommendations: [SetupRecommendation]
    ) {
        self.generatedAt = generatedAt
        self.client = client
        self.auditGeneratedAt = auditGeneratedAt
        self.summary = summary
        self.recommendations = recommendations.sorted { $0.priority < $1.priority }
    }
}

// MARK: - Command shapes

/// How each client is asked to review the audit. Two shapes each: one that
/// may read the tooling folders and nothing else, and one that may also
/// search the web and read the apps' own documentation. Neither may run a
/// command or write a file, and neither is given the conversation stores or
/// the sign-in and secret files inside those folders.
enum SetupReviewCommandShapes {
    static let codexSchemaFileName = "setup-review-schema.json"

    /// Public client configuration folders, relative to home.
    static let readableFolders = [".codex", ".agents", ".claude", ".gemini", ".kiro"]

    /// Where the apps keep what was said, typed, pasted, dictated or attached
    /// inside those folders, which the review is never given, whatever the
    /// folders allow. First the two Let your assistant help names, where
    /// Claude Code and Codex keep their conversations; then Kiro CLI's
    /// sessions, Codex's archived sessions, its attachments and dictation,
    /// and Claude Code's sessions, the files it edited as they were, and what
    /// was pasted into it.
    static let withheldFolders = [
        ".claude/projects", ".codex/sessions", ".kiro/sessions", ".kiro/session-index", ".codex/archived_sessions",
        ".codex/attachments", ".codex/dictation-history", ".claude/sessions", ".claude/file-history", ".claude/paste-cache",
    ]

    /// The conversation stores kept as single files, withheld the same way:
    /// the databases this app's own scanner reads, each app's history of what
    /// was typed into it, and Codex's index of its sessions and its
    /// transcriptions. Each rule ends in `*`, so a database's journal and
    /// write-ahead files, and a history's rotated copies, are withheld with
    /// it.
    static let withheldFiles = [
        ".codex/thread_history_1.sqlite", ".claude/__store.db", ".codex/history.jsonl", ".claude/history.jsonl",
        ".codex/session_index.jsonl", ".codex/transcription-history.jsonl",
    ]

    /// The two withheld folders Let your assistant help names: the ones Claude
    /// Code and Codex keep conversations in.
    static let namedWithheldFolders = Array(withheldFolders.prefix(2))

    /// Where the apps keep sign-in tokens, keys and copies of their settings
    /// inside those folders, which the review is never given either, apart
    /// from conversation history: Claude Code's backups of its settings file,
    /// its shell and environment captures, its editor connections (which
    /// hold a token) and its debug logs; Codex's shell captures and logs;
    /// Kiro CLI's sign-in helpers and logs.
    static let secretFolders = [
        ".claude/backups", ".claude/shell-snapshots", ".claude/session-env", ".claude/ide", ".claude/debug",
        ".codex/shell_snapshots", ".codex/log", ".kiro/crew", ".kiro/crew-auth-staging", ".kiro/logs",
    ]

    /// The sign-in and secret files kept singly, withheld the same way, each
    /// rule ending in `*`: Codex's, Claude Code's and Gemini CLI's sign-ins,
    /// Gemini CLI's account list, its connections' tokens and its
    /// environment file, Codex's log databases, and Kiro CLI's shell history.
    static let secretFiles = [
        ".codex/auth.json", ".codex/.credentials.json", ".claude/.credentials.json", ".gemini/oauth_creds.json",
        ".gemini/google_accounts.json", ".gemini/mcp-oauth-tokens", ".gemini/.env", ".codex/logs_", ".kiro/.cli_bash_history",
    ]

    /// Files that hold a secret wherever they sit inside a readable folder, a
    /// place no list names among them: environment files, keys,
    /// certificates, anything named for a secret or a credential, and a
    /// vault.
    static let secretPatterns = ["**/.env*", "**/*.key", "**/*.pem", "**/*.p12", "**/*secret*", "**/*credential*", "**/.vault/**"]

    /// The documentation the one-app review may read on the web: each app's
    /// own documentation sites, one fixed list for every app, so the shape
    /// stays one shape. Any other address is refused, so nothing the review
    /// reads can be sent anywhere a fetch would reach. Release notes are
    /// fetched by Agent Tooling itself and handed over in the prompt.
    static let documentationHosts = [
        "developers.openai.com", "platform.openai.com", "help.openai.com", "docs.anthropic.com", "docs.claude.com",
        "code.claude.com", "geminicli.com", "google-gemini.github.io", "kiro.dev",
    ]

    /// A Read rule for `relative` under the home folder, anchored at the
    /// root of the file system. Claude Code reads a rule that starts with one
    /// slash as relative to its working directory, where it silently matches
    /// nothing; two slashes make it absolute.
    static func readRule(homeURL: URL, _ relative: String, isFolder: Bool = true) -> String {
        "Read(/" + ProcessCommandRunner.plainPath(of: homeURL) + "/" + relative + (isFolder ? "/**" : "*") + ")"
    }

    /// The deny rules: every withheld folder and file, then every secret
    /// folder, file and pattern, the patterns under each readable folder.
    /// Claude Code applies a deny rule before any allow rule, so a folder's
    /// allow rule never lifts one of these.
    static func withheldRules(homeURL: URL) -> [String] {
        withheldFolders.map { readRule(homeURL: homeURL, $0) }
            + withheldFiles.map { readRule(homeURL: homeURL, $0, isFolder: false) }
            + secretRules(homeURL: homeURL)
    }

    /// The deny rules for the sign-in and secret places
    /// (`secretFolders`, `secretFiles`, `secretPatterns`).
    static func secretRules(homeURL: URL) -> [String] {
        let patterns = readableFolders.flatMap { folder in
            secretPatterns.map { "Read(/" + ProcessCommandRunner.plainPath(of: homeURL) + "/" + folder + "/" + $0 + ")" }
        }
        return secretFolders.map { readRule(homeURL: homeURL, $0) }
            + secretFiles.map { readRule(homeURL: homeURL, $0, isFolder: false) } + patterns
    }

    static func claude(homeURL: URL, web: Bool) -> [String] {
        var arguments = [
            "-p", "--output-format", "json",
            "--json-schema", responseSchemaJSON,
            "--permission-mode", "plan",
            "--strict-mcp-config",
            "--setting-sources", "user",
            "--allowedTools",
        ]
        // Read rules are what let Glob and Grep reach these folders too; a
        // bare Glob or Grep would search anywhere.
        arguments += readableFolders.map { readRule(homeURL: homeURL, $0) }
        if web { arguments += ["WebSearch"] + documentationHosts.map { "WebFetch(domain:\($0))" } }
        arguments += ["--disallowedTools", "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Task"]
        if !web { arguments += ["WebFetch", "WebSearch"] }
        arguments += withheldRules(homeURL: homeURL)
        return arguments
    }

    /// Codex reads inside its sandbox; `--cd` is the home folder so the tooling
    /// folders are in reach, and read-only keeps it a reader. `--search` is the
    /// only difference for a client review.
    static func codex(homeURL: URL, requestDirectory: URL, web: Bool) -> [String] {
        var arguments = [
            "exec", "--json", "--ephemeral",
            "--ignore-rules",
            "--disable", "plugins", "--disable", "hooks", "--disable", "apps", "--disable", "remote_plugin",
            "--sandbox", "read-only",
            "--skip-git-repo-check", "--color", "never",
            "--cd", homeURL.path(percentEncoded: false),
            "--output-schema", requestDirectory.appending(path: codexSchemaFileName).path(percentEncoded: false),
        ]
        if web { arguments.append("--search") }
        arguments.append("-")
        return arguments
    }

    static func isClaudeShape(_ arguments: [String], homeURL: URL) -> Bool {
        arguments == claude(homeURL: homeURL, web: false) || arguments == claude(homeURL: homeURL, web: true)
    }

    static func isCodexShape(_ arguments: [String], homeURL: URL) -> Bool {
        guard let index = arguments.firstIndex(of: "--output-schema"), arguments.indices.contains(index + 1) else { return false }
        let schemaPath = arguments[index + 1]
        guard schemaPath.hasSuffix("/" + codexSchemaFileName) else { return false }
        let requestDirectory = URL(filePath: schemaPath).deletingLastPathComponent()
        guard SkillCreatorCommandShapes.isRequestDirectoryPath(requestDirectory.path(percentEncoded: false), homeURL: homeURL) else {
            return false
        }
        return arguments == codex(homeURL: homeURL, requestDirectory: requestDirectory, web: false)
            || arguments == codex(homeURL: homeURL, requestDirectory: requestDirectory, web: true)
    }

    static let categories = SetupRecommendation.Category.allCases.map(\.rawValue)
    static let actionKinds = [
        "take_finding_action", "set_setting", "install_plugin", "disable_mcp_server", "read_only",
    ]
    static let clients = ["claude", "codex", "kiro", "gemini"]

    static var responseSchema: [String: Any] {
        [
            "type": "object", "additionalProperties": false,
            "required": ["summary", "recommendations"],
            "properties": [
                "summary": ["type": "string", "maxLength": 800],
                "recommendations": [
                    "type": "array", "maxItems": 40,
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "required": ["category", "title", "summary", "rationale", "priority", "action", "provenance"],
                        "properties": [
                            "category": ["type": "string", "enum": categories],
                            "title": ["type": "string", "maxLength": 120],
                            "summary": ["type": "string", "maxLength": 400],
                            "rationale": ["type": "string", "maxLength": 600],
                            "client": ["type": "string", "enum": clients],
                            "priority": ["type": "integer", "minimum": 1, "maximum": 100],
                            "finding_ids": ["type": "array", "maxItems": 60, "items": ["type": "string", "maxLength": 32]],
                            "provenance": [
                                "type": "object", "additionalProperties": false, "required": ["kind"],
                                "properties": [
                                    "kind": ["type": "string", "enum": ["audit", "investigated", "opinion"]],
                                    "finding_id": ["type": "string", "maxLength": 32],
                                    "source": ["type": "string", "maxLength": 300],
                                ],
                            ],
                            "action": [
                                "type": "object", "additionalProperties": false, "required": ["kind"],
                                "properties": [
                                    "kind": ["type": "string", "enum": actionKinds],
                                    "finding_id": ["type": "string", "maxLength": 32],
                                    "action_index": ["type": "integer", "minimum": 0, "maximum": 20],
                                    "client": ["type": "string", "enum": clients],
                                    "key": ["type": "string", "maxLength": 120],
                                    "value": ["type": "string", "maxLength": 400],
                                    "plugin_id": ["type": "string", "maxLength": 200],
                                    "server": ["type": "string", "maxLength": 120],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    static var responseSchemaJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: responseSchema, options: [.sortedKeys]) else {
            preconditionFailure("The built-in setup review response schema must be JSON encodable.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The prompt

public enum SetupReviewPrompt {
    public enum Purpose: String, Sendable {
        /// The recurring check: what has drifted since things were decided.
        case checkup
        /// One client: what changed upstream, what the docs now recommend.
        case clientReview
    }

    static let maximumPromptBytes = 160 * 1_024

    /// The most redacted conversation summaries one review is handed, newest
    /// first. Let your assistant help and the notice quote it, through
    /// `AssistantRunLimits`.
    static let maximumDigests = 40

    public static func render(
        purpose: Purpose, audit: SetupAuditReport, digests: [ConversationDigest], focus client: ClientKind?,
        clientVersions: [ClientKind: String], releaseNotes: [String] = []
    ) -> String {
        let shapes = SetupReviewCommandShapes.self
        let withheld = (shapes.withheldFolders + shapes.withheldFiles).joined(separator: ", ")
        let secrets = (shapes.secretFolders + shapes.secretFiles).joined(separator: ", ")
        let patterns = shapes.secretPatterns.map { $0.replacingOccurrences(of: "**/", with: "") }.joined(separator: ", ")
        var text = """
            You are reviewing how one person's AI coding assistants are set up on their Mac, and proposing what to change. \
            The person uses \(audit.clients.map(\.rawValue).joined(separator: ", ")). \
            Below is a deterministic audit of what is on the disk, as typed findings with ids, each with the actions the app can take for it. \
            You may read the assistants' own configuration folders (\(shapes.readableFolders.joined(separator: ", ")) under the home folder) to understand a finding better; you cannot change anything, and you must not try. \
            Do not read anything outside those folders, and do not read the conversation history inside them (\(withheld)). \
            Do not read sign-in or secret files, backups, shell captures or logs inside them either (\(secrets)), nor any file matching \(patterns); no finding needs them, and never repeat a token, key or password in your answer.

            """
        switch purpose {
        case .checkup:
            text +=
                "This is a routine check. Report drift: what is broken, duplicated, or unmanaged now, and the smallest set of changes that fixes it. If nothing needs doing, say so in one sentence and return no recommendations.\n"
        case .clientReview:
            let name = client?.rawValue ?? "the client"
            text +=
                "This is a review of \(name) alone. Its installed version is \(client.flatMap { clientVersions[$0] } ?? "unknown"). Using the release notes below and, if they are not enough, the client's official documentation on the web (search the web, and fetch pages only from \(SetupReviewCommandShapes.documentationHosts.joined(separator: ", "))), say what has changed since that version that matters to this person, which settings, hooks, skills, plugins, or MCP servers the documentation now recommends that differ from what is configured, and what is deprecated. Every claim about the client must name the page or release it came from as its provenance source. Do not invent features.\n"
        }
        text += """

            Rules for the answer: every recommendation must carry provenance. Use kind "audit" with the finding id when a finding grounds it; "investigated" with the file path or URL you read when you looked something up; "opinion" only when neither applies. \
            For an action, prefer "take_finding_action" with the finding id and the index of the action to take from that finding's list. Use "set_setting" only for a key you saw documented, with the exact value. \
            Give each recommendation a priority from 1 (do first) to 100. Keep the list short and grounded; fewer, well-supported items beat many weak ones. \
            Answer only with the JSON the schema describes.

            ## Installed versions
            \(clientVersions.sorted { $0.key.rawValue < $1.key.rawValue }.map { "- \($0.key.rawValue): \($0.value)" }.joined(separator: "\n"))

            ## What each app holds
            \(audit.counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "- \($0.key.rawValue): \($0.value.skills) skills, \($0.value.plugins) plugins, \($0.value.mcpServers) MCP servers" }.joined(separator: "\n"))

            ## Audit findings (\(audit.findings.count))

            """
        let relevant = client.map { c in audit.findings.filter { $0.client == c || $0.client == nil } } ?? audit.findings
        var used = 0
        for finding in relevant {
            var entry = "### \(finding.id) · \(finding.kind.rawValue) · \(finding.severity.rawValue)"
            if let c = finding.client { entry += " · \(c.rawValue)" }
            entry += "\n\(finding.title)\n\(finding.detail)"
            if !finding.evidence.isEmpty { entry += "\nevidence: " + finding.evidence.prefix(6).joined(separator: " | ") }
            for (index, action) in finding.actions.enumerated() { entry += "\naction[\(index)]: \(action.title)" }
            entry += "\n\n"
            guard text.utf8.count + entry.utf8.count <= maximumPromptBytes else { break }
            text += entry
            used += 1
        }
        if used < relevant.count {
            text += "(\(relevant.count - used) more findings omitted for length; they are all of the same kinds.)\n\n"
        }
        if !releaseNotes.isEmpty {
            text += "## Release notes and documentation fetched for you\n\n"
            for note in releaseNotes {
                guard text.utf8.count + note.utf8.count <= maximumPromptBytes else { break }
                text += note + "\n\n"
            }
        }
        if !digests.isEmpty {
            text += "## How the person has been working lately (redacted digests, newest first)\n\n"
            for digest in digests.sorted(by: { $0.endedAt > $1.endedAt }).prefix(maximumDigests) {
                var entry = "- \(digest.client.rawValue)"
                if let project = digest.workingDirectory { entry += " · \(project)" }
                if !digest.skillsUsed.isEmpty { entry += " · skills: \(digest.skillsUsed.joined(separator: ", "))" }
                if let first = digest.userMessages.first { entry += " · \"\(String(first.prefix(160)))\"" }
                entry += "\n"
                guard text.utf8.count + entry.utf8.count <= maximumPromptBytes else { break }
                text += entry
            }
        }
        return text
    }
}

// MARK: - The service

enum SetupReviewError: LocalizedError, Equatable, Sendable {
    case unsupportedClient(ClientKind)
    case commandRefused(ClientKind)
    case clientFailed(ClientKind, Int32, String)
    case unreadableAnswer(ClientKind)

    var errorDescription: String? {
        switch self {
        case .unsupportedClient(let client): "\(client.rawValue) cannot run the review."
        case .commandRefused(let client):
            "The command the review would run for \(client.rawValue) is not one this app allows, so it was not run."
        case .clientFailed(let client, let status, let diagnostic):
            "\(client.rawValue) could not finish the review (exit \(status)). \(diagnostic)"
        case .unreadableAnswer(let client): "\(client.rawValue) answered, but not in the shape the review asked for."
        }
    }
}

/// Runs a policy-validated model review with the prompt on stdin and a fixed
/// response schema. Claude Code starts in an empty staged request folder with
/// scoped Read rules; Codex uses a read-only sandbox at home. The child's HOME
/// is the review's configured home, keeping scratch runs isolated.
public struct SetupReviewService: Sendable {
    private let runner: any StandardInputCommandRunning
    private let stagingRootURL: URL
    private let homeURL: URL
    private let policy: OperationCommandPolicy

    /// How long one review may run before it is stopped.
    static let timeout: Duration = .seconds(1_200)

    /// `runner` defaults to one over `homeURL`, with the review's timeout.
    public init(
        stagingRootURL: URL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: (any StandardInputCommandRunning)? = nil
    ) {
        self.stagingRootURL = stagingRootURL
        self.homeURL = homeURL
        self.runner = runner ?? ProcessCommandRunner(timeout: Self.timeout, homeURL: homeURL)
        self.policy = OperationCommandPolicy(
            libraryURL: homeURL.appending(path: ".agent-tooling/library", directoryHint: .isDirectory),
            gitBackupRoot: homeURL.appending(path: ".agent-tooling/git-backup", directoryHint: .isDirectory),
            homeURL: homeURL)
    }

    public func run(
        client: ClientKind, purpose: SetupReviewPrompt.Purpose, audit: SetupAuditReport, digests: [ConversationDigest],
        focus: ClientKind?, clientVersions: [ClientKind: String], releaseNotes: [String] = []
    ) async throws -> SetupReview {
        guard client == .claude || client == .codex else { throw SetupReviewError.unsupportedClient(client) }
        let web = purpose == .clientReview
        let prompt = SetupReviewPrompt.render(
            purpose: purpose, audit: audit, digests: digests, focus: focus, clientVersions: clientVersions,
            releaseNotes: releaseNotes)

        let requestURL = stagingRootURL.appending(path: "request-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: requestURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: requestURL) }

        let executable =
            ClientExecutableLocator.locate(client, homeURL: homeURL)?.path(percentEncoded: false)
            ?? ClientExecutableLocator.executableName(for: client)
        let arguments: [String]
        switch client {
        case .claude:
            arguments = SetupReviewCommandShapes.claude(homeURL: homeURL, web: web)
        default:
            try Data(SetupReviewCommandShapes.responseSchemaJSON.utf8).write(
                to: requestURL.appending(path: SetupReviewCommandShapes.codexSchemaFileName), options: .atomic)
            arguments = SetupReviewCommandShapes.codex(homeURL: homeURL, requestDirectory: requestURL, web: web)
        }
        do { try policy.validate(executable: executable, arguments: arguments) } catch { throw SetupReviewError.commandRefused(client) }

        let output = try await runner.run(
            executable: executable, arguments: arguments, standardInput: Data(prompt.utf8),
            currentDirectory: client == .claude ? requestURL : homeURL)
        let answer: [String: Any]
        do {
            answer =
                client == .claude
                ? try InsightsDeepDiveService.parseClaude(output, client: client)
                : try InsightsDeepDiveService.parseCodex(output, client: client)
        } catch let error as InsightsDeepDiveError {
            switch error {
            case .clientFailed(let c, let status, let diagnostic): throw SetupReviewError.clientFailed(c, status, diagnostic)
            case .unreadableAnswer(let c): throw SetupReviewError.unreadableAnswer(c)
            default: throw SetupReviewError.unreadableAnswer(client)
            }
        }
        return Self.review(from: answer, client: client, audit: audit)
    }

    /// The answer as this app's types, bounded again in case the schema was
    /// not honoured. A recommendation naming a finding or an action that does
    /// not exist is dropped, not guessed at.
    static func review(from answer: [String: Any], client: ClientKind, audit: SetupAuditReport, now: Date = .now) -> SetupReview {
        let findings = Dictionary(uniqueKeysWithValues: audit.findings.map { ($0.id, $0) })
        func bounded(_ value: Any?, _ limit: Int) -> String { String(((value as? String) ?? "").prefix(limit)) }
        func clientKind(_ value: Any?) -> ClientKind? {
            switch value as? String {
            case "claude": .claude
            case "codex": .codex
            case "kiro": .kiro
            case "gemini": .gemini
            default: nil
            }
        }
        var recommendations: [SetupRecommendation] = []
        for (index, raw) in ((answer["recommendations"] as? [[String: Any]]) ?? []).prefix(40).enumerated() {
            guard let category = SetupRecommendation.Category(rawValue: bounded(raw["category"], 20)) else { continue }
            let title = bounded(raw["title"], 120)
            guard !title.isEmpty else { continue }
            let ids = ((raw["finding_ids"] as? [String]) ?? []).filter { findings[$0] != nil }
            let provenanceRaw = raw["provenance"] as? [String: Any] ?? [:]
            let provenance: SetupRecommendationProvenance
            switch bounded(provenanceRaw["kind"], 20) {
            case "audit":
                guard let id = provenanceRaw["finding_id"] as? String, findings[id] != nil else { continue }
                provenance = .audit(findingID: id)
            case "investigated":
                let source = bounded(provenanceRaw["source"], 300)
                guard !source.isEmpty else { continue }
                provenance = .investigated(source: SensitiveValueRedactor.redact(source))
            default:
                provenance = .opinion
            }
            let actionRaw = raw["action"] as? [String: Any] ?? [:]
            let action: SetupRecommendationAction
            switch bounded(actionRaw["kind"], 30) {
            case "take_finding_action":
                guard let id = actionRaw["finding_id"] as? String, let finding = findings[id],
                    let offset = actionRaw["action_index"] as? Int, finding.actions.indices.contains(offset)
                else { continue }
                action = .take(finding.actions[offset])
            case "set_setting":
                guard let c = clientKind(actionRaw["client"]) else { continue }
                let key = bounded(actionRaw["key"], 120)
                guard !key.isEmpty else { continue }
                action = .setSetting(client: c, key: key, value: bounded(actionRaw["value"], 400))
            case "install_plugin":
                guard let c = clientKind(actionRaw["client"]) else { continue }
                let pluginID = bounded(actionRaw["plugin_id"], 200)
                guard OperationCommandPolicy.isSafePluginIdentifier(pluginID) else { continue }
                action = .installPlugin(client: c, pluginID: pluginID)
            case "disable_mcp_server":
                guard let c = clientKind(actionRaw["client"]) else { continue }
                let server = bounded(actionRaw["server"], 120)
                guard OperationCommandPolicy.isSafeMCPIdentifier(server) else { continue }
                action = .disableMCPServer(client: c, name: server)
            default:
                action = .readOnly
            }
            let slug = title.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").prefix(6).joined(
                separator: "-")
            recommendations.append(
                SetupRecommendation(
                    id: "review:\(client.rawValue.lowercased().filter(\.isLetter)):\(index):\(slug)", category: category, title: title,
                    summary: bounded(raw["summary"], 400), rationale: bounded(raw["rationale"], 600),
                    client: clientKind(raw["client"]), priority: max(1, min(100, raw["priority"] as? Int ?? 50)),
                    provenance: provenance, action: action, findingIDs: ids))
        }
        return SetupReview(
            generatedAt: now, client: client, auditGeneratedAt: audit.generatedAt,
            summary: bounded(answer["summary"], 800), recommendations: recommendations)
    }
}

// MARK: - What the assistant's runs read and send

/// What the assistant's own runs may read and what they send, as the words
/// that describe them quote it: Let your assistant help, Settings › General
/// and Home's notice name these folders and numbers, so the copy is built from
/// the same values the commands and prompts are, and cannot promise less than
/// they do.
public enum AssistantRunLimits {
    /// The folders the weekly review may read, relative to home, in the app
    /// order.
    public static var reviewFolders: [String] { SetupReviewCommandShapes.readableFolders }
    /// The two conversation folders the review is never given that the
    /// weekly card names: Claude Code's, then Codex's.
    public static var namedWithheldFolders: [String] { SetupReviewCommandShapes.namedWithheldFolders }
    /// The most redacted conversation summaries the weekly review sends.
    public static var reviewDigests: Int { SetupReviewPrompt.maximumDigests }
    /// The most the daily deep dive sends.
    public static var deepDiveDigests: Int { InsightsDeepDivePrompt.maximumDigests }
    /// What one summary keeps at most: the first messages of a conversation,
    /// each cut to a length.
    public static var messagesPerDigest: Int { ConversationDigestBuilder.maximumUserMessages }
    public static var charactersPerMessage: Int { ConversationDigestBuilder.maximumUserMessageCharacters }
    /// How far back the scheduled scans read.
    public static var lookbackDays: Int { InsightScanOptions().lookbackDays }
    /// The apps whose conversation history this app can read at all, and so
    /// the only sources a summary or a keyword scan can come from.
    public static var historyClients: Set<ClientKind> { InsightScanOptions(clients: Set(ClientKind.allCases)).bounded.clients }
}
