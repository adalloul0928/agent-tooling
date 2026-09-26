import Foundation

// MARK: - Conversation records

/// One thing said in a skill-creation conversation: by the person, by the
/// client, or by this app when it needs to note something (a turn that was
/// refused, a draft that could not be read).
public struct SkillDraftMessage: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case person
        case assistant
        case note
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var sentAt: Date

    public init(id: UUID = UUID(), role: Role, text: String, sentAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.sentAt = sentAt
    }
}

/// What one turn of the conversation produced: the client's reply, anything
/// the app wants to add, and the draft package as it stands afterwards.
///
/// `draft` is nil when the folder holds no package yet — a clarifying question
/// writes nothing — and `draftIssue` says why an existing package could not be
/// shown, so a half-written draft reads as "not ready" rather than as failure.
public struct SkillDraftTurn: Hashable, Sendable {
    public var reply: SkillDraftMessage
    public var notes: [String]
    public var draft: SkillDraftResult?
    public var draftIssue: String?

    public init(reply: SkillDraftMessage, notes: [String] = [], draft: SkillDraftResult? = nil, draftIssue: String? = nil) {
        self.reply = reply
        self.notes = notes
        self.draft = draft
        self.draftIssue = draftIssue
    }
}

/// The conversation as kept beside the staged draft, so a sheet that was
/// closed and reopened shows the same exchange and can carry it on.
///
/// `sessionID` is what the client uses to resume: the UUID this app chose for
/// Claude Code, or the thread identifier Codex reported. Nothing in here is a
/// credential.
public struct SkillDraftConversation: Codable, Hashable, Sendable {
    public static let maximumMessages = 200
    public static let maximumMessageCharacters = 32_768

    public var request: SkillDraftRequest
    public var sessionID: String?
    public var messages: [SkillDraftMessage]

    public init(request: SkillDraftRequest, sessionID: String? = nil, messages: [SkillDraftMessage] = []) {
        self.request = request
        self.sessionID = sessionID
        self.messages = messages
    }
}

/// Whether a client can run its skill creator right now.
public enum SkillCreatorAvailability: Hashable, Sendable {
    case available
    /// Not installed. `installArguments` is the exact command that installs it,
    /// when this app knows one; nil when only the person can fix it.
    case missing(reason: String, executable: String?, installArguments: [String]?)
    case unsupportedClient
}

// MARK: - Command shapes

/// The exact argument lists the creator runs, in one place so the adapters
/// that build them and the policy that admits them cannot drift apart.
///
/// Prompts travel on standard input, never on the command line: they are
/// long, they are the person's words, and argv is visible to every process
/// on the Mac.
public enum SkillCreatorCommandShapes {
    /// Claude Code, answering one prompt and exiting. Tools that would edit
    /// files are auto-accepted only inside the working directory, which is the
    /// staged request folder; MCP servers and project settings are left out
    /// so a turn is fast and touches nothing else; Bash and the web are
    /// disallowed so the creator writes files and nothing more.
    public static func claude(sessionID: UUID, resuming: Bool) -> [String] {
        [
            "-p", "--output-format", "json",
            resuming ? "--resume" : "--session-id", sessionID.uuidString.lowercased(),
            "--permission-mode", "acceptEdits",
            "--strict-mcp-config",
            "--setting-sources", "user",
            "--disallowedTools", "Bash", "WebFetch", "WebSearch", "Task", "NotebookEdit",
        ]
    }

    /// Codex, starting a thread in the staged request folder. The thread is
    /// kept (no `--ephemeral`) so later turns can resume it.
    public static func codexStart(requestDirectory: URL) -> [String] {
        [
            "exec", "--json",
            "--ignore-user-config", "--ignore-rules",
            "--disable", "plugins", "--disable", "hooks", "--disable", "apps", "--disable", "remote_plugin",
            "--enable", "code_mode_host",
            "--sandbox", "workspace-write",
            "--skip-git-repo-check", "--color", "never",
            "--cd", requestDirectory.path(percentEncoded: false),
            "-",
        ]
    }

    /// Codex, continuing a thread it reported. `resume` takes fewer flags than
    /// `exec`; the sandbox is restated through `-c` because the resumed thread
    /// must not gain what the first turn never had.
    public static func codexResume(threadID: String) -> [String] {
        [
            "exec", "resume", threadID, "--json",
            "--ignore-user-config", "--ignore-rules",
            "--disable", "plugins", "--disable", "hooks", "--disable", "apps", "--disable", "remote_plugin",
            "--enable", "code_mode_host",
            "-c", "sandbox_mode=workspace-write",
            "--skip-git-repo-check",
            "-",
        ]
    }

    /// The Claude marketplace plugin that carries the skill creator, and the
    /// commands that add it. Installing needs the marketplace to be known to
    /// Claude Code first; both shapes are admitted by the policy.
    public static let claudeSkillCreatorPluginID = "skill-creator@claude-plugins-official"
    public static let claudeOfficialMarketplaceAddArguments = ["plugin", "marketplace", "add", "anthropics/claude-plugins-official"]
    public static var claudeSkillCreatorInstallArguments: [String] {
        ["plugin", "install", claudeSkillCreatorPluginID, "--scope", "user"]
    }

    /// Whether `arguments` is exactly one of the Claude shapes above, for the
    /// policy. The session identifier is the only variable part and must be a
    /// UUID.
    public static func isClaudeCreatorShape(_ arguments: [String]) -> Bool {
        guard arguments.count > 4, let sessionID = UUID(uuidString: arguments[4]) else { return false }
        return arguments == claude(sessionID: sessionID, resuming: true)
            || arguments == claude(sessionID: sessionID, resuming: false)
    }

    /// Whether `arguments` is exactly one of the Codex shapes above, for the
    /// policy. A start's folder must be an absolute, normalized path under
    /// `homeURL` whose last component is a request folder; a resume's thread
    /// identifier must be a UUID.
    public static func isCodexCreatorShape(_ arguments: [String], homeURL: URL) -> Bool {
        if arguments.count > 2, arguments[1] == "resume" {
            guard UUID(uuidString: arguments[2]) != nil else { return false }
            return arguments == codexResume(threadID: arguments[2])
        }
        guard let index = arguments.firstIndex(of: "--cd"), arguments.indices.contains(index + 1) else { return false }
        let path = arguments[index + 1]
        guard isRequestDirectoryPath(path, homeURL: homeURL) else { return false }
        return arguments == codexStart(requestDirectory: URL(filePath: path, directoryHint: .isDirectory))
    }

    static func isRequestDirectoryPath(_ path: String, homeURL: URL) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("/../"), !path.hasSuffix("/.."),
            path.count <= 1_024
        else { return false }
        let home = homeURL.standardizedFileURL.path(percentEncoded: false)
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(homePrefix) else { return false }
        let lastComponent = URL(filePath: path).lastPathComponent
        guard lastComponent.hasPrefix("request-"), UUID(uuidString: String(lastComponent.dropFirst("request-".count))) != nil
        else { return false }
        return URL(filePath: path).standardizedFileURL.path(percentEncoded: false) == path
    }
}

// MARK: - Client adapters

/// What one turn's output boiled down to, before the app reads the draft.
struct SkillCreatorParsedTurn: Sendable {
    var reply: String
    var sessionID: String?
    var notes: [String]
    var failed: Bool
}

enum SkillCreatorParseError: Error, Equatable, Sendable {
    case unreadableOutput
}

/// How one client is asked to run its skill creator and how its answer is
/// read. The service owns everything else: the staging folder, the prompt's
/// output contract, the policy check, and reading the draft back.
protocol SkillCreatorClientAdapter: Sendable {
    var client: ClientKind { get }
    var executable: String { get }
    /// How the kickoff prompt tells this client to bring in its skill creator.
    func creatorInvocation(skillCreatorPath: String?) -> String
    /// The first turn. `sessionID` is the identifier this app chose; a client
    /// that names its own sessions ignores it and reports its own.
    func startArguments(sessionID: UUID, requestDirectory: URL) -> [String]
    /// A later turn in the same conversation.
    func continueArguments(sessionID: String, requestDirectory: URL) -> [String]
    func parse(_ output: CommandOutput) throws -> SkillCreatorParsedTurn
}

/// Claude Code in print mode. One JSON document comes back per turn.
struct ClaudeSkillCreatorAdapter: SkillCreatorClientAdapter {
    let client = ClientKind.claude
    let executable = "claude"

    func creatorInvocation(skillCreatorPath: String?) -> String {
        "Use the skill-creator skill from the installed skill-creator plugin "
            + "(invoke it as /skill-creator:skill-creator) and follow its guidance for authoring the skill. "
            + "Bash is not available in this session, so write every file directly instead of running the plugin's scripts."
    }

    func startArguments(sessionID: UUID, requestDirectory: URL) -> [String] {
        SkillCreatorCommandShapes.claude(sessionID: sessionID, resuming: false)
    }

    func continueArguments(sessionID: String, requestDirectory: URL) -> [String] {
        guard let uuid = UUID(uuidString: sessionID) else { return [] }
        return SkillCreatorCommandShapes.claude(sessionID: uuid, resuming: true)
    }

    /// The `result` document: `result` is the reply, `session_id` the
    /// conversation, `is_error` whether the turn failed, and
    /// `permission_denials` the tools Claude wanted and was refused — worth
    /// telling the person, since a refused write means the draft did not
    /// change the way the reply may claim.
    func parse(_ output: CommandOutput) throws -> SkillCreatorParsedTurn {
        guard let start = output.standardOutput.firstIndex(of: "{"),
            let document = try? JSONSerialization.jsonObject(
                with: Data(output.standardOutput[start...].utf8)) as? [String: Any]
        else {
            if output.status != 0 { return SkillCreatorParsedTurn(reply: "", sessionID: nil, notes: [], failed: true) }
            throw SkillCreatorParseError.unreadableOutput
        }
        var notes: [String] = []
        let denials = (document["permission_denials"] as? [[String: Any]]) ?? []
        if !denials.isEmpty {
            let names = Set(denials.compactMap { $0["tool_name"] as? String }).sorted()
            notes.append(
                "Claude Code asked to use \(names.joined(separator: ", ")) and was refused: only files inside the draft folder may be written here.")
        }
        let isError = (document["is_error"] as? Bool) ?? (output.status != 0)
        let reply = (document["result"] as? String) ?? ""
        if isError, reply.isEmpty {
            notes.append("Claude Code ended the turn with an error (\((document["subtype"] as? String) ?? "unknown")).")
        }
        return SkillCreatorParsedTurn(
            reply: reply, sessionID: document["session_id"] as? String, notes: notes, failed: isError)
    }
}

/// Codex in `exec` mode. One JSON event per line comes back per turn.
struct CodexSkillCreatorAdapter: SkillCreatorClientAdapter {
    let client = ClientKind.codex
    let executable = "codex"

    func creatorInvocation(skillCreatorPath: String?) -> String {
        var text = "Use `$skill-creator`."
        if let skillCreatorPath {
            text += " First read and follow its installed instructions at:\n\(skillCreatorPath)"
        }
        return text
    }

    func startArguments(sessionID: UUID, requestDirectory: URL) -> [String] {
        SkillCreatorCommandShapes.codexStart(requestDirectory: requestDirectory)
    }

    func continueArguments(sessionID: String, requestDirectory: URL) -> [String] {
        SkillCreatorCommandShapes.codexResume(threadID: sessionID)
    }

    /// `thread.started` names the thread to resume; the last `agent_message`
    /// item is the reply; `error` items are Codex's own warnings. Its
    /// configuration warnings ("ignoring unrecognized setting") are dropped,
    /// because they are about the person's Codex config, not this draft.
    func parse(_ output: CommandOutput) throws -> SkillCreatorParsedTurn {
        var reply = ""
        var sessionID: String?
        var notes: [String] = []
        var sawEvent = false
        for line in output.standardOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let type = event["type"] as? String
            else { continue }
            sawEvent = true
            switch type {
            case "thread.started":
                sessionID = event["thread_id"] as? String
            case "item.completed":
                guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String else { continue }
                if kind == "agent_message", let text = item["text"] as? String, !text.isEmpty {
                    reply = text
                } else if kind == "error", let message = item["message"] as? String,
                    !message.contains("unrecognized configuration"), !message.contains("skills context budget")
                {
                    notes.append(message)
                }
            case "turn.failed", "error":
                if let message = (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String {
                    notes.append(message)
                }
            default:
                continue
            }
        }
        if !sawEvent {
            if output.status != 0 { return SkillCreatorParsedTurn(reply: "", sessionID: nil, notes: [], failed: true) }
            throw SkillCreatorParseError.unreadableOutput
        }
        return SkillCreatorParsedTurn(reply: reply, sessionID: sessionID, notes: notes, failed: output.status != 0)
    }
}

enum SkillCreatorClientAdapters {
    /// The adapter for a client that has a skill creator this app can drive.
    static func adapter(for client: ClientKind) -> (any SkillCreatorClientAdapter)? {
        switch client {
        case .claude: ClaudeSkillCreatorAdapter()
        case .codex: CodexSkillCreatorAdapter()
        case .gemini, .kiro: nil
        }
    }
}

// MARK: - Availability

/// Where each client keeps the skill creator, so the app can say whether a
/// conversation can start before it tries.
public enum SkillCreatorLocator {
    /// Claude Code records installed plugins in its config directory. Reading
    /// that file is instant and needs no process; the CLI would say the same.
    public static func claudeAvailability(
        homeURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SkillCreatorAvailability {
        let configDirectory: URL
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            configDirectory = URL(filePath: configured, directoryHint: .isDirectory)
        } else {
            configDirectory = homeURL.appending(path: ".claude", directoryHint: .isDirectory)
        }
        let file = configDirectory.appending(path: "plugins/installed_plugins.json", directoryHint: .notDirectory)
        let missing = SkillCreatorAvailability.missing(
            reason: "Claude Code does not have the skill-creator plugin installed.",
            executable: "claude",
            installArguments: SkillCreatorCommandShapes.claudeSkillCreatorInstallArguments)
        guard let text = try? BoundedFileAccess.readUTF8(at: file, maximumBytes: 1_048_576, allowSymbolicLink: false),
            let document = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let plugins = document["plugins"] as? [String: Any]
        else { return missing }
        return plugins[SkillCreatorCommandShapes.claudeSkillCreatorPluginID] != nil ? .available : missing
    }

    /// Codex ships its skill creator as a system skill; there is nothing to
    /// install, only a Codex too old to have it.
    public static func codexAvailability(skillCreatorURL: URL) -> SkillCreatorAvailability {
        guard let values = try? skillCreatorURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true
        else {
            return .missing(
                reason: "Codex's built-in skill creator was not found at \(skillCreatorURL.path(percentEncoded: false)). Update Codex to a version that includes it.",
                executable: nil, installArguments: nil)
        }
        return .available
    }
}
