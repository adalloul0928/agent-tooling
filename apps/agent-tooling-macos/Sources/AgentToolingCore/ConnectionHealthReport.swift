import Foundation

/// Turns a client's health listing into structured entries, and nothing else.
///
/// This is a pure function over text on purpose. The probe that runs the
/// command is where timeouts, output limits and executable location live; the
/// parsing is separated out so every status shape a client can print is pinned
/// down by a test against a fixed string, with no process involved. A shape
/// this parser has not seen becomes `.unknown(rawText:)` carrying the line, so
/// an unfamiliar client update is shown verbatim rather than misread.
enum ConnectionHealthReport {
    /// Parses one client's listing. Claude Code prints a status glyph per line;
    /// Codex and Kiro CLI list servers without a health check, so their entries
    /// come back `.unknown` unless a later `mcp get` says otherwise.
    static func parse(client: ClientKind, text: String) -> [ConnectionHealthEntry] {
        switch client {
        case .claude: parseClaude(text)
        case .codex: parseNameFirstTable(text, client: .codex, unknownText: codexUnknownText)
        case .kiro: parseNameFirstTable(text, client: .kiro, unknownText: kiroUnknownText)
        case .gemini: []
        }
    }

    private static let codexUnknownText = "Codex does not report connection health in its listing."
    private static let kiroUnknownText = "Kiro CLI lists servers without a connection health check."

    /// Parses Codex's `mcp list --json` when it answered JSON, falling back to
    /// the text table when it did not. Codex reports no health in either shape,
    /// so every server is `.unknown` here; a status only arrives from `mcp get`.
    static func parseCodex(jsonOrText text: String) -> [ConnectionHealthEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
            let data = trimmed.data(using: .utf8),
            let entries = parseCodexJSON(data)
        {
            return entries
        }
        return parseNameFirstTable(text, client: .codex, unknownText: codexUnknownText)
    }

    // MARK: - Claude

    private static func parseClaude(_ text: String) -> [ConnectionHealthEntry] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseClaudeLine(String($0)) }
    }

    /// One Claude line looks like `<name>: <command or url> - <glyph> <state>`.
    /// The status is read off the glyph and the words after it; the summary is
    /// the middle, redacted. A header line such as "Checking MCP server health…"
    /// has no `: … -` shape and is skipped.
    private static func parseClaudeLine(_ rawLine: String) -> ConnectionHealthEntry? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        // A health line is "name: <summary> - <state>". The name ends at the
        // first ": " (colon then space); a `plugin:foo:bar` name keeps its own
        // colons because none of them is followed by a space, and a URL's
        // "https://" colon comes later in the summary.
        guard let nameSeparator = line.range(of: ": ") else { return nil }
        let name = String(line[line.startIndex..<nameSeparator.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(" ") || isClaudeAIConnectorName(name) else {
            // A sentence ("Checking MCP server health…") has spaces before its
            // first ": ", if it has one at all. A server name does not, with
            // one documented exception: Claude Code names each claude.ai
            // connector `claude.ai <display name>`, and a display name such as
            // "Google Calendar" has spaces of its own.
            return nil
        }
        let remainder = String(line[nameSeparator.upperBound...]).trimmingCharacters(in: .whitespaces)
        // The status is the segment after the last " - ". Splitting on the last
        // occurrence keeps a command that itself contains " - " in the summary.
        guard let separator = remainder.range(of: " - ", options: .backwards) else {
            return nil
        }
        var summary = String(remainder[remainder.startIndex..<separator.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        // Claude Code prints "- Not configured" as a status, so the line reads
        // "url - - Not configured" and the summary would keep a stray dash.
        if summary.hasSuffix(" -") { summary = String(summary.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        let statusText = String(remainder[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        let status = claudeStatus(from: statusText)
        let source = claudeSource(name: name, summary: summary, statusText: statusText)
        let displayName = displayName(from: name)
        return ConnectionHealthEntry(
            client: .claude,
            name: name,
            displayName: displayName,
            source: source,
            status: status,
            summary: SensitiveValueRedactor.redact(summary),
            rawLine: rawLine)
    }

    /// Maps the words after the glyph to a state. The glyphs are matched by the
    /// state word beside them rather than the symbol, so a client that swaps a
    /// glyph but keeps the wording still reads correctly; a wholly unfamiliar
    /// tail is kept verbatim as `.unknown`.
    private static func claudeStatus(from statusText: String) -> ConnectionHealthStatus {
        let lowered = statusText.lowercased()
        if lowered.contains("connected") { return .connected }
        if lowered.contains("needs authentication") { return .needsAuthentication }
        if lowered.contains("pending approval") { return .pendingApproval }
        if lowered.contains("disabled") { return .disabled }
        if lowered.contains("not configured") { return .notConfigured }
        if lowered.contains("connection error") { return .failed(detail: failureDetail(from: statusText)) }
        if lowered.contains("failed to connect") {
            // The reason is printed after the em dash (or a hyphen fallback).
            let detail = failureDetail(from: statusText)
            return .failed(detail: detail)
        }
        return .unknown(rawText: statusText)
    }

    /// Pulls the human reason out of "Failed to connect — <detail>". The em
    /// dash is what Claude prints; a plain hyphen is accepted too so a terminal
    /// that rewrote it still yields the detail rather than an empty string.
    private static func failureDetail(from statusText: String) -> String {
        for separator in [" — ", " – ", " - "] {
            if let range = statusText.range(of: separator) {
                return String(statusText[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func claudeSource(name: String, summary: String, statusText: String) -> ConnectionHealthSource {
        if name.hasPrefix("plugin:") {
            // `plugin:<plugin>:<server>` — the plugin is the middle segment.
            let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2 { return .plugin(String(parts[1])) }
            return .plugin("")
        }
        if isClaudeAIConnectorName(name) { return .claudeAI }
        let haystack = (summary + " " + statusText).lowercased()
        if haystack.contains("claude.ai") || haystack.contains("connector") {
            return .claudeAI
        }
        return .unknown
    }

    /// The prefix Claude Code gives every connector it fetches from claude.ai,
    /// verified against Claude Code 2.1.300: the server is listed as
    /// `claude.ai <display name>`, with ` (2)` appended on a name collision.
    /// The same string is what a `deniedMcpServers` `serverName` entry
    /// matches, so it is kept whole as the entry's name.
    static let claudeAIConnectorPrefix = "claude.ai "

    static func isClaudeAIConnectorName(_ name: String) -> Bool {
        name.hasPrefix(claudeAIConnectorPrefix) && name.count > claudeAIConnectorPrefix.count
    }

    // MARK: - Codex

    private static func parseCodexJSON(_ data: Data) -> [ConnectionHealthEntry]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // Codex has printed either an object keyed by server name or an array
        // of server objects. Both are accepted; anything else falls back to the
        // text reader.
        if let dictionary = object as? [String: Any] {
            let servers = dictionary["mcpServers"] as? [String: Any] ?? dictionary
            return servers.keys.sorted().compactMap { key in
                codexEntry(name: key, fields: servers[key] as? [String: Any] ?? [:])
            }
        }
        if let array = object as? [[String: Any]] {
            return array.compactMap { fields in
                guard let name = fields["name"] as? String else { return nil }
                return codexEntry(name: name, fields: fields)
            }
        }
        return nil
    }

    private static func codexEntry(name: String, fields: [String: Any]) -> ConnectionHealthEntry? {
        guard !name.isEmpty else { return nil }
        let url = (fields["url"] as? String).map { $0 }
        let command = fields["command"] as? String
        let args = (fields["args"] as? [String])?.joined(separator: " ")
        let summary = url ?? [command, args].compactMap { $0 }.joined(separator: " ")
        return ConnectionHealthEntry(
            client: .codex,
            name: name,
            displayName: name,
            source: .unknown,
            status: .unknown(rawText: "Codex does not report connection health in its listing."),
            summary: SensitiveValueRedactor.redact(summary),
            rawLine: name)
    }

    /// Reads a name-first table that carries no health, which is how both Codex
    /// and Kiro CLI list their servers: the first field on a line is the server
    /// name and the rest is the summary, with a header row and any rule of
    /// dashes skipped. Every entry is `.unknown` carrying `unknownText`, since a
    /// status only arrives later from a per-server query.
    private static func parseNameFirstTable(
        _ text: String, client: ClientKind, unknownText: String
    ) -> [ConnectionHealthEntry] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                let lowered = line.lowercased()
                // Skip a header row and any rule of dashes under it.
                if lowered.hasPrefix("name") && lowered.contains("command") { return nil }
                if line.allSatisfy({ $0 == "-" || $0 == " " || $0 == "|" }) { return nil }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let name = fields.first, !name.hasPrefix("-") else { return nil }
                let summary = fields.dropFirst().joined(separator: " ")
                return ConnectionHealthEntry(
                    client: client,
                    name: name,
                    displayName: name,
                    source: .unknown,
                    status: .unknown(rawText: unknownText),
                    summary: SensitiveValueRedactor.redact(summary),
                    rawLine: String(rawLine))
            }
    }

    // MARK: - Shared

    /// Strips a `plugin:` prefix down to the server's own name for display,
    /// leaving anything else as it was printed.
    private static func displayName(from name: String) -> String {
        if isClaudeAIConnectorName(name) { return String(name.dropFirst(claudeAIConnectorPrefix.count)) }
        guard name.hasPrefix("plugin:") else { return name }
        let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        // `plugin:<plugin>:<server>` shows the server; a shorter shape shows
        // whatever followed the prefix rather than an empty string.
        if parts.count >= 3 { return String(parts[2]) }
        if parts.count == 2 { return String(parts[1]) }
        return name
    }
}
