import Foundation

/// The shape a pasted block turned out to have. It is reported back to the
/// person so the import sheet can say what it read, not merely what it kept.
public enum PastedShape: String, Codable, Hashable, Sendable {
    case claudeCommand
    case codexCommand
    case geminiCommand
    case json
    case url
    case skillMarkdown

    public var displayName: String {
        switch self {
        case .claudeCommand: "Claude Code command"
        case .codexCommand: "Codex command"
        case .geminiCommand: "Gemini CLI command"
        case .json: "MCP JSON"
        case .url: "Server URL"
        case .skillMarkdown: "SKILL.md"
        }
    }
}

/// One server understood from a paste, with the plain-language record of what
/// was read, adjusted, or deliberately dropped.
public struct PastedMCPServerDraft: Identifiable, Equatable, Sendable {
    public var draft: MCPDraft
    public var notes: [String]

    public init(draft: MCPDraft, notes: [String] = []) {
        self.draft = draft
        self.notes = notes
    }

    public var id: String { draft.name }
}

public struct PastedMCPImport: Equatable, Sendable {
    public var shape: PastedShape
    public var servers: [PastedMCPServerDraft]
    public var notes: [String]

    public init(shape: PastedShape, servers: [PastedMCPServerDraft], notes: [String] = []) {
        self.shape = shape
        self.servers = servers
        self.notes = notes
    }
}

public struct PastedSkillImport: Equatable, Sendable {
    public var draft: SkillDraft
    public var notes: [String]
    /// Fields the paste could not supply. The sheet keeps creation disabled
    /// until the person fills them in, rather than inventing them.
    public var missingFields: [String]

    public init(draft: SkillDraft, notes: [String] = [], missingFields: [String] = []) {
        self.draft = draft
        self.notes = notes
        self.missingFields = missingFields
    }
}

public enum PastedDefinition: Equatable, Sendable {
    case mcp(PastedMCPImport)
    case skill(PastedSkillImport)
}

public enum PasteImportError: LocalizedError, Equatable, Sendable {
    case empty
    case tooLong(Int)
    case unsupportedCharacters
    case multipleCommands(Int)
    case unreadableCommand(String)
    case unsupportedExecutable(String)
    case notAnAddCommand(String)
    case unknownFlag(String)
    case missingFlagValue(String)
    case missingServerName
    case missingDestination
    case invalidDestination(String)
    case invalidJSON(String)
    case noServersInJSON
    case invalidSkill(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "There was nothing to read. Paste an mcp add command, an MCP JSON block, a server URL, or a SKILL.md file."
        case .tooLong(let maximum):
            "The pasted text is longer than \(maximum) characters. Paste one server definition or one SKILL.md file."
        case .unsupportedCharacters:
            "The pasted text contains control characters this app will not read. Paste plain text."
        case .multipleCommands(let count):
            "\(count) command lines were pasted. Paste one mcp add command at a time so its plan can be reviewed on its own."
        case .unreadableCommand(let reason):
            "The command could not be read: \(reason)"
        case .unsupportedExecutable(let value):
            "Only claude, codex, and gemini mcp add commands can be imported. This command starts with \(value)."
        case .notAnAddCommand(let value):
            "Only mcp add commands can be imported. This command reads \(value)."
        case .unknownFlag(let flag):
            "The command uses \(flag), which this app does not understand. Remove it, or add the server through the form."
        case .missingFlagValue(let flag):
            "\(flag) has no value in the pasted command."
        case .missingServerName:
            "The command has no server name after mcp add."
        case .missingDestination:
            "The paste has no endpoint or command for the server."
        case .invalidDestination(let reason):
            reason
        case .invalidJSON(let reason):
            "The pasted JSON could not be read: \(reason)"
        case .noServersInJSON:
            "No MCP server was found in the pasted JSON. Expected an mcpServers object, or one server object with a command or url."
        case .invalidSkill(let reason):
            "The pasted SKILL.md could not be read: \(reason)"
        }
    }
}

/// Reads a pasted definition as data. Nothing here executes, evaluates, or
/// resolves anything: the text is bounded, scanned for control characters, and
/// mapped onto the same drafts the forms produce, so a plan is still reviewed
/// before any client changes.
public enum PastedDefinitionParser {
    public static let maximumInputLength = 16_384
    public static let maximumServerCount = 24

    public static func parse(_ raw: String) throws -> PastedDefinition {
        let text = try normalized(raw)
        if text.hasPrefix("---") {
            return .skill(try parseSkill(text))
        }
        if text.hasPrefix("{") {
            return .mcp(try parseJSON(text))
        }
        if let url = singleWebURL(in: text) {
            return .mcp(try parseURL(url))
        }
        return .mcp(try parseCommand(text))
    }

    // MARK: - Bounds

    private static func normalized(_ raw: String) throws -> String {
        guard raw.count <= maximumInputLength else { throw PasteImportError.tooLong(maximumInputLength) }
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard
            !unified.unicodeScalars.contains(where: { scalar in
                (scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A) || scalar.value == 0x7F
            })
        else { throw PasteImportError.unsupportedCharacters }
        let trimmed = unified.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PasteImportError.empty }
        return trimmed
    }

    // MARK: - Command lines

    private static func parseCommand(_ text: String) throws -> PastedMCPImport {
        let joined = text.replacingOccurrences(of: "\\\n", with: " ")
        let lines =
            joined
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let first = lines.first else { throw PasteImportError.empty }
        guard lines.count == 1 else { throw PasteImportError.multipleCommands(lines.count) }

        let tokens = try commandTokens(in: stripPrompt(first))
        guard let executable = tokens.first else { throw PasteImportError.empty }
        let client: ClientKind
        let shape: PastedShape
        switch executable.lowercased() {
        case "claude":
            client = .claude
            shape = .claudeCommand
        case "codex":
            client = .codex
            shape = .codexCommand
        case "gemini":
            client = .gemini
            shape = .geminiCommand
        default:
            throw PasteImportError.unsupportedExecutable(executable)
        }

        var rest = Array(tokens.dropFirst())
        let subcommand = rest.count > 1 ? rest[1].lowercased() : ""
        guard rest.first?.lowercased() == "mcp", ["add", "add-json"].contains(subcommand) else {
            throw PasteImportError.notAnAddCommand(tokens.prefix(3).joined(separator: " "))
        }
        rest.removeFirst(2)

        var parsed = ParsedFlags()
        try readFlags(rest, into: &parsed)

        guard let rawName = parsed.positionals.first else { throw PasteImportError.missingServerName }
        var notes: [String] = ["Read as a \(shape.displayName); \(client.rawValue) is preselected."]

        if subcommand == "add-json" {
            guard parsed.positionals.count > 1 else { throw PasteImportError.missingDestination }
            var server = try draft(named: rawName, from: try jsonObject(parsed.positionals[1]))
            server.draft.scope = parsed.scope
            server.draft.addToClaude = client == .claude
            server.draft.addToCodex = client == .codex
            server.draft.addToGemini = client == .gemini
            server.notes = notes + parsed.notes + server.notes
            appendScopeNoteIfNeeded(server.draft, notes: &server.notes)
            return PastedMCPImport(shape: shape, servers: [server])
        }

        let name = try sanitizedName(rawName, notes: &notes)

        let transport: MCPTransport
        let endpoint: String
        if let url = parsed.url {
            transport = parsed.transport ?? .http
            endpoint = url
        } else if !parsed.separatedCommand.isEmpty {
            transport = parsed.transport ?? .stdio
            endpoint = shellQuoted(parsed.separatedCommand)
        } else if parsed.positionals.count > 1 {
            let remainder = Array(parsed.positionals.dropFirst())
            if let candidate = remainder.first, remainder.count == 1, isWebURL(candidate) {
                transport = parsed.transport ?? .http
                endpoint = candidate
            } else {
                transport = parsed.transport ?? .stdio
                endpoint = shellQuoted(remainder)
            }
        } else {
            throw PasteImportError.missingDestination
        }

        notes.append(contentsOf: parsed.notes)
        var draft = MCPDraft()
        draft.name = name
        draft.endpoint = endpoint
        draft.transport = transport
        draft.scope = parsed.scope
        draft.authentication = suggestedAuthentication(transport: transport, secretNames: parsed.secretNames)
        draft.addToClaude = client == .claude
        draft.addToCodex = client == .codex
        draft.addToGemini = client == .gemini
        try validateDestination(&draft)
        appendScopeNoteIfNeeded(draft, notes: &notes)
        return PastedMCPImport(shape: shape, servers: [PastedMCPServerDraft(draft: draft, notes: notes)])
    }

    private struct ParsedFlags {
        var transport: MCPTransport?
        var scope: ToolingScope = .user
        var url: String?
        var positionals: [String] = []
        var separatedCommand: [String] = []
        var secretNames: [String] = []
        var notes: [String] = []
    }

    private static func readFlags(_ tokens: [String], into parsed: inout ParsedFlags) throws {
        var index = 0
        var afterSeparator = false
        var droppedEnvironment: [String] = []
        var droppedHeaders: [String] = []
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if afterSeparator {
                parsed.separatedCommand.append(token)
                continue
            }
            if token == "--" {
                afterSeparator = true
                continue
            }
            // Once the name and the executable have been read, the rest of the
            // line belongs to the server command, flags included.
            guard token.hasPrefix("-"), token.count > 1, parsed.positionals.count < 2 else {
                parsed.positionals.append(token)
                continue
            }
            let (flag, inlineValue) = splitInlineValue(token)
            let value: String
            switch flag {
            case "--transport", "-t", "--scope", "-s", "--url", "--env", "-e", "--header", "-H":
                if let inlineValue {
                    value = inlineValue
                } else {
                    guard index < tokens.count else { throw PasteImportError.missingFlagValue(flag) }
                    value = tokens[index]
                    index += 1
                }
            default:
                throw PasteImportError.unknownFlag(flag)
            }
            switch flag {
            case "--transport", "-t":
                parsed.transport = try readTransport(value, notes: &parsed.notes)
            case "--scope", "-s":
                parsed.scope = try readScope(value, notes: &parsed.notes)
            case "--url":
                parsed.url = value
            case "--env", "-e":
                let name = secretName(in: value)
                droppedEnvironment.append(name)
                parsed.secretNames.append(name)
            default:
                let name = secretName(in: value)
                droppedHeaders.append(name)
                parsed.secretNames.append(name)
            }
        }
        if !droppedEnvironment.isEmpty {
            parsed.notes.append(
                "Environment values were not copied: \(droppedEnvironment.joined(separator: ", ")). Set them in the app's credential flow."
            )
        }
        if !droppedHeaders.isEmpty {
            parsed.notes.append(
                "Header values were not copied: \(droppedHeaders.joined(separator: ", ")). Authentication stays with the client."
            )
        }
    }

    private static func readTransport(_ value: String, notes: inout [String]) throws -> MCPTransport {
        switch value.lowercased() {
        case "stdio":
            return .stdio
        case "http":
            return .http
        case "sse", "streamable-http", "streamablehttp", "http-sse":
            notes.append("Transport \(value) was recorded as HTTP. Confirm the app's own transport flag before approving the plan.")
            return .http
        default:
            throw PasteImportError.unreadableCommand("\(value) is not a transport this app configures.")
        }
    }

    private static func readScope(_ value: String, notes: inout [String]) throws -> ToolingScope {
        switch value.lowercased() {
        case "user", "global":
            return .user
        case "project":
            return .project
        case "local":
            notes.append("Scope local was read as This project only.")
            return .localProject
        case "workspace":
            return .workspace
        default:
            throw PasteImportError.unreadableCommand("\(value) is not a scope this app configures.")
        }
    }

    private static func splitInlineValue(_ token: String) -> (String, String?) {
        guard let separator = token.firstIndex(of: "=") else { return (token, nil) }
        return (String(token[..<separator]), String(token[token.index(after: separator)...]))
    }

    /// Keeps the name of a credential and never its value.
    private static func secretName(in value: String) -> String {
        let beforeEquals = value.split(separator: "=", maxSplits: 1).first.map(String.init) ?? value
        return beforeEquals.split(separator: ":", maxSplits: 1).first.map(String.init) ?? beforeEquals
    }

    private static func stripPrompt(_ line: String) -> String {
        for prefix in ["$ ", "% ", "> "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }

    private static func commandTokens(in line: String) throws -> [String] {
        do {
            return try MCPDefinitionValidator.parseCommandLine(line)
        } catch {
            throw PasteImportError.unreadableCommand(error.localizedDescription)
        }
    }

    // MARK: - JSON

    private static func jsonObject(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else { throw PasteImportError.invalidJSON("It is not valid UTF-8 text.") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PasteImportError.invalidJSON(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw PasteImportError.invalidJSON("The top level must be one JSON object.")
        }
        return root
    }

    private static func parseJSON(_ text: String) throws -> PastedMCPImport {
        let root = try jsonObject(text)

        var named: [(String, [String: Any])] = []
        if let servers = (root["mcpServers"] ?? root["servers"]) as? [String: Any] {
            named = servers.keys.sorted().compactMap { key in
                guard let value = servers[key] as? [String: Any] else { return nil }
                return (key, value)
            }
            guard named.count == servers.count else {
                throw PasteImportError.invalidJSON("Every entry under mcpServers must be an object.")
            }
        } else if root["command"] != nil || root["url"] != nil || root["type"] != nil {
            named = [((root["name"] as? String) ?? "", root)]
        } else if root.count == 1, let key = root.keys.first, let value = root[key] as? [String: Any] {
            named = [(key, value)]
        }
        guard !named.isEmpty else { throw PasteImportError.noServersInJSON }
        guard named.count <= maximumServerCount else {
            throw PasteImportError.invalidJSON("The block declares \(named.count) servers; at most \(maximumServerCount) can be read.")
        }

        var servers: [PastedMCPServerDraft] = []
        var failures: [String] = []
        for (name, body) in named {
            do {
                servers.append(try draft(named: name, from: body))
            } catch {
                failures.append("\(name.isEmpty ? "the server" : name): \(error.localizedDescription)")
            }
        }
        guard !servers.isEmpty else { throw PasteImportError.invalidJSON(failures.joined(separator: " · ")) }
        var notes: [String] = []
        if !failures.isEmpty {
            notes.append("Skipped \(failures.count) entry that could not be read — \(failures.joined(separator: " · "))")
        }
        return PastedMCPImport(shape: .json, servers: servers, notes: notes)
    }

    private static func draft(named rawName: String, from body: [String: Any]) throws -> PastedMCPServerDraft {
        var notes: [String] = []
        var secretNames: [String] = []
        if let environment = body["env"] as? [String: Any], !environment.isEmpty {
            let names = environment.keys.sorted()
            secretNames.append(contentsOf: names)
            notes.append("Environment values were not copied: \(names.joined(separator: ", ")).")
        }
        if let headers = body["headers"] as? [String: Any], !headers.isEmpty {
            let names = headers.keys.sorted()
            secretNames.append(contentsOf: names)
            notes.append("Header values were not copied: \(names.joined(separator: ", ")).")
        }

        let declaredType = (body["type"] as? String ?? body["transport"] as? String)?.lowercased()
        let transport: MCPTransport
        let endpoint: String
        var suggestion: String?
        if let url = body["url"] as? String {
            transport = .http
            endpoint = url
            suggestion = suggestedName(fromURL: url)
            if let declaredType, !["http", "sse", "streamable-http", "streamablehttp"].contains(declaredType) {
                notes.append("Type \(declaredType) was recorded as HTTP because the entry declares a url.")
            }
        } else if let command = body["command"] as? String {
            guard body["args"] == nil || body["args"] is [String] else {
                throw PasteImportError.invalidJSON("args must be an array of strings.")
            }
            transport = .stdio
            let arguments = (body["args"] as? [String]) ?? []
            endpoint = shellQuoted([command] + arguments)
            suggestion = suggestedName(fromCommand: [command] + arguments)
        } else {
            throw PasteImportError.invalidJSON("It declares neither a command nor a url.")
        }

        let ignored = Set(body.keys).subtracting(["type", "transport", "url", "command", "args", "env", "headers", "name"])
        if !ignored.isEmpty {
            notes.append("Ignored fields: \(ignored.sorted().joined(separator: ", ")).")
        }

        let candidateName = rawName.isEmpty ? (suggestion ?? "") : rawName
        guard !candidateName.isEmpty else {
            throw PasteImportError.invalidJSON("It has no name, and no name could be suggested from its command or url.")
        }
        if rawName.isEmpty {
            notes.append("The JSON had no name; \(candidateName) was suggested from its \(transport == .http ? "url" : "command").")
        }

        var draft = MCPDraft()
        draft.name = try sanitizedName(candidateName, notes: &notes)
        draft.endpoint = endpoint
        draft.transport = transport
        draft.authentication = suggestedAuthentication(transport: transport, secretNames: secretNames)
        try validateDestination(&draft)
        return PastedMCPServerDraft(draft: draft, notes: notes)
    }

    // MARK: - Bare URL

    private static func parseURL(_ url: String) throws -> PastedMCPImport {
        var notes: [String] = []
        guard let suggestion = suggestedName(fromURL: url) else {
            throw PasteImportError.invalidDestination("A server name could not be suggested from \(url). Name it in the form.")
        }
        notes.append("Read as an HTTP endpoint; \(suggestion) was suggested from its address.")
        var draft = MCPDraft()
        draft.name = try sanitizedName(suggestion, notes: &notes)
        draft.endpoint = url
        draft.transport = .http
        draft.authentication = "OAuth"
        try validateDestination(&draft)
        return PastedMCPImport(shape: .url, servers: [PastedMCPServerDraft(draft: draft, notes: notes)])
    }

    private static func singleWebURL(in text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.contains(where: \.isWhitespace), isWebURL(candidate) else { return nil }
        return candidate
    }

    private static func isWebURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme)
        else { return false }
        return components.host?.isEmpty == false
    }

    // MARK: - SKILL.md

    private static func parseSkill(_ text: String) throws -> PastedSkillImport {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw PasteImportError.invalidSkill("The frontmatter has no closing --- line.")
        }
        var fields: [String: String] = [:]
        var ignored: [String] = []
        for line in lines[1..<closing] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = yamlScalar(String(trimmed[trimmed.index(after: separator)...]))
            if ["name", "description"].contains(key) {
                fields[key] = value
            } else if !key.isEmpty {
                ignored.append(key)
            }
        }
        guard let rawName = fields["name"], !rawName.isEmpty else {
            throw PasteImportError.invalidSkill("The frontmatter has no name field.")
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw PasteImportError.invalidSkill("The frontmatter has no description field.")
        }
        guard description.count <= WorkspaceLibrary.maximumPurposeLength else {
            throw PasteImportError.invalidSkill("The description is longer than \(WorkspaceLibrary.maximumPurposeLength) characters.")
        }

        var notes: [String] = []
        let name = try sanitizedName(rawName, notes: &notes)
        let body = lines[(closing + 1)...].joined(separator: "\n")
        var triggers = sectionBullets(in: body, heading: "when to use")
        if triggers.isEmpty {
            triggers = sentences(in: description).filter(isTriggerSentence)
        }
        triggers = Array(triggers.prefix(3))
        var negative = sectionText(in: body, heading: "when not to use")
        if negative.isEmpty {
            negative = sentences(in: description).first(where: isNegativeSentence) ?? ""
        }

        var draft = SkillDraft()
        draft.name = name
        draft.purpose = description
        draft.triggers = triggers + Array(repeating: "", count: max(0, 3 - triggers.count))
        draft.negativeTrigger = String(negative.prefix(WorkspaceLibrary.maximumNegativeTriggerLength))
        draft.runCanary = false

        if !ignored.isEmpty {
            notes.append("Ignored frontmatter fields: \(ignored.sorted().joined(separator: ", ")).")
        }
        notes.append("Only the frontmatter was read. Body text, scripts, and references were not imported.")
        var missing: [String] = []
        if triggers.isEmpty { missing.append("At least one trigger") }
        if draft.negativeTrigger.isEmpty { missing.append("A negative trigger") }
        return PastedSkillImport(draft: draft, notes: notes, missingFields: missing)
    }

    private static func yamlScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
            (trimmed.first == "\"" && trimmed.last == "\"") || (trimmed.first == "'" && trimmed.last == "'")
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func sectionBullets(in body: String, heading: String) -> [String] {
        sectionLines(in: body, heading: heading)
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= WorkspaceLibrary.maximumTriggerLength }
    }

    private static func sectionText(in body: String, heading: String) -> String {
        sectionLines(in: body, heading: heading)
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func sectionLines(in body: String, heading: String) -> [String] {
        var collected: [String] = []
        var inside = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if inside { break }
                inside = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased().contains(heading)
                continue
            }
            if inside { collected.append(line) }
        }
        return collected
    }

    private static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= WorkspaceLibrary.maximumTriggerLength }
    }

    private static func isTriggerSentence(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["use when", "use this when", "use it when", "use for", "trigger on", "use whenever"].contains { lowered.contains($0) }
    }

    private static func isNegativeSentence(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["do not use", "don't use", "not for", "never use"].contains { lowered.contains($0) }
    }

    // MARK: - Shared

    private static func validateDestination(_ draft: inout MCPDraft) throws {
        do {
            draft.endpoint = try MCPDefinitionValidator.validate(draft.endpoint, transport: draft.transport).endpoint
        } catch {
            throw PasteImportError.invalidDestination(error.localizedDescription)
        }
    }

    private static func appendScopeNoteIfNeeded(_ draft: MCPDraft, notes: inout [String]) {
        guard draft.scope != .user else { return }
        notes.append("Choose the project folder for this \(draft.scope.displayName.lowercased()) server before continuing.")
    }

    private static func suggestedAuthentication(transport: MCPTransport, secretNames: [String]) -> String {
        let looksLikeCredential = secretNames.contains { name in
            let lowered = name.lowercased()
            return ["key", "token", "secret", "password", "authorization"].contains { lowered.contains($0) }
        }
        if looksLikeCredential { return "API key" }
        return transport == .http ? "OAuth" : "None"
    }

    static func suggestedName(fromURL value: String) -> String? {
        guard let host = URLComponents(string: value)?.host?.lowercased() else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        let noise = ["www", "mcp", "api", "com", "io", "net", "org", "dev", "ai", "app", "co"]
        return labels.first(where: { !noise.contains($0) }) ?? labels.first
    }

    static func suggestedName(fromCommand tokens: [String]) -> String? {
        let candidates = tokens.filter { !$0.hasPrefix("-") }
        for token in candidates.reversed() {
            let tail = token.split(separator: "/").last.map(String.init) ?? token
            let cleaned = tail.replacingOccurrences(of: "@", with: "")
            guard cleaned.count > 1, cleaned.contains(where: \.isLetter) else { continue }
            return cleaned
        }
        return candidates.first
    }

    /// Names arrive from other tools in shapes this app's identifiers do not
    /// allow. The adjustment is always reported instead of applied silently.
    static func sanitizedName(_ raw: String, notes: inout [String]) throws -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        for character in lowered {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
            } else if ["-", "_", ".", " ", "/", "@", ":"].contains(String(character)) {
                result.append("-")
            }
        }
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = String(result.prefix(WorkspaceLibrary.maximumIdentifierLength))
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !result.isEmpty else {
            throw PasteImportError.invalidDestination("\(raw) cannot be used as a name. Names use letters, numbers, and hyphens.")
        }
        if result != raw {
            notes.append("Name read as \(result).")
        }
        return result
    }

    static func shellQuoted(_ tokens: [String]) -> String {
        tokens
            .map { token in
                token.isEmpty || token.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
                    ? "'\(token.replacingOccurrences(of: "'", with: "'\\''"))'" : token
            }
            .joined(separator: " ")
    }
}
