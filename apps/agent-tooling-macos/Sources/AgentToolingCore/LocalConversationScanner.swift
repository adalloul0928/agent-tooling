import Foundation
import SQLite3

private let insightsSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct LocalConversationScanner: Sendable {
    private let maximumClaudeTranscriptBytes: Int

    public init(maximumClaudeTranscriptBytes: Int = 128 * 1_024 * 1_024) {
        self.maximumClaudeTranscriptBytes = min(max(maximumClaudeTranscriptBytes, 1_024), 512 * 1_024 * 1_024)
    }

    func scan(
        options requestedOptions: InsightScanOptions,
        skills: [Skill],
        homeURL: URL,
        now: Date
    ) -> ConversationScanArtifact {
        let options = requestedOptions.bounded
        let windowStart = now.addingTimeInterval(-Double(options.lookbackDays) * 86_400)
        let lookup = SkillNameLookup(skills: skills)
        var artifact = ConversationScanArtifact(windowStart: windowStart)

        if options.clients.contains(.codex) {
            artifact.merge(
                scanCodex(
                    homeURL: homeURL,
                    windowStart: windowStart,
                    options: options,
                    skillLookup: lookup
                )
            )
        }
        if options.clients.contains(.claude) {
            let jsonlResult = scanClaudeJSONL(
                homeURL: homeURL,
                windowStart: windowStart,
                options: options,
                skillLookup: lookup
            )
            if jsonlResult.hasObservableSource {
                artifact.merge(jsonlResult)
            } else {
                if jsonlResult.coverage.contains(where: { $0.status == .degraded }) {
                    artifact.merge(jsonlResult)
                }
                artifact.merge(
                    scanClaudeSQLite(
                        homeURL: homeURL,
                        windowStart: windowStart,
                        options: options
                    )
                )
            }
        }

        return artifact
    }

    private func scanCodex(
        homeURL: URL,
        windowStart: Date,
        options: InsightScanOptions,
        skillLookup: SkillNameLookup
    ) -> ConversationScanArtifact {
        var artifact = ConversationScanArtifact(windowStart: windowStart)
        let databaseURL = homeURL.appending(path: ".codex/thread_history_1.sqlite")
        let unavailable = ConversationScanCoverage(
            client: .codex,
            sourceID: "codex-thread-history-sqlite-v1",
            sourceName: "Codex local thread history",
            status: .unavailable,
            detail: "Codex history tracking is unavailable. Usage counts remain a lower bound."
        )

        do {
            let database = try ReadOnlyInsightsDatabase(url: databaseURL, containedBy: homeURL)
            let cutoff = windowStart.timeIntervalSince1970 * 1_000
            let queriedConversations = try database.queryConversationIDs(
                sql: """
                    SELECT thread_id, MAX(created_at_ms)
                    FROM thread_items
                    WHERE created_at_ms >= ?
                    GROUP BY thread_id
                    ORDER BY MAX(created_at_ms) DESC
                    LIMIT ?
                    """,
                cutoff: cutoff,
                limit: options.maximumConversationsPerClient + 1
            )
            let conversations = Array(queriedConversations.prefix(options.maximumConversationsPerClient))
            var latestItemAt: Date?
            var inspected = 0
            var skipped = 0
            var wasTruncated = queriedConversations.count > options.maximumConversationsPerClient

            for conversation in conversations {
                let queriedRows = try database.queryRows(
                    sql: """
                        SELECT item_type, item_json, created_at_ms, turn_id
                        FROM (
                            SELECT item_type, item_json, created_at_ms, turn_id
                            FROM thread_items
                            WHERE thread_id = ? AND created_at_ms >= ?
                            ORDER BY created_at_ms DESC
                            LIMIT ?
                        )
                        ORDER BY created_at_ms ASC
                        """,
                    conversationID: conversation.id,
                    cutoff: cutoff,
                    limit: options.maximumItemsPerConversation + 1,
                    maximumTextBytes: options.maximumItemBytes
                )
                if queriedRows.count > options.maximumItemsPerConversation { wasTruncated = true }
                let rows = queriedRows.suffix(options.maximumItemsPerConversation)
                for (ordinal, candidate) in rows.enumerated() {
                    guard let row = candidate else {
                        skipped += 1
                        continue
                    }
                    latestItemAt = maxDate(latestItemAt, row.date(milliseconds: true))
                    guard let object = parseJSONObject(row.payload) else {
                        skipped += 1
                        continue
                    }
                    inspected += 1
                    switch row.kind {
                    case "userMessage":
                        if let text = messageText(from: object), !text.isEmpty {
                            artifact.messages.append(
                                .init(
                                    conversationID: conversation.id,
                                    client: .codex,
                                    date: row.date(milliseconds: true),
                                    tokens: insightTokens(from: sanitizeConversationText(text))
                                )
                            )
                            for skillID in explicitlyReferencedSkills(in: text, lookup: skillLookup) {
                                artifact.evidence.insert(
                                    UsageEvidence(
                                        key: "codex:inferred:\(conversation.id):\(row.turnID ?? "item-\(ordinal)"):\(skillID)",
                                        skillID: skillID,
                                        precision: .inferred,
                                        provenance: .codexExplicitReference,
                                        client: .codex,
                                        date: row.date(milliseconds: true)
                                    )
                                )
                            }
                        }
                    case "commandExecution":
                        for command in commandStrings(from: object) {
                            for skillID in skillDefinitionReferences(in: command, lookup: skillLookup) {
                                artifact.evidence.insert(
                                    UsageEvidence(
                                        key: "codex:inferred:\(conversation.id):\(row.turnID ?? "item-\(ordinal)"):\(skillID)",
                                        skillID: skillID,
                                        precision: .inferred,
                                        provenance: .skillDefinitionRead,
                                        client: .codex,
                                        date: row.date(milliseconds: true)
                                    )
                                )
                            }
                        }
                    default:
                        break
                    }
                }
            }

            artifact.coverage = [
                ConversationScanCoverage(
                    client: .codex,
                    sourceID: "codex-thread-history-sqlite-v1",
                    sourceName: "Codex local thread history",
                    status: (wasTruncated || skipped > 0) ? .degraded : .scanned,
                    conversationsScanned: conversations.count,
                    itemsInspected: inspected,
                    itemsSkipped: skipped,
                    latestItemAt: latestItemAt,
                    supportsUsageAttribution: true,
                    detail: skipped > 0
                        ? skippedItemDetail(
                            skipped,
                            suffix: "Explicit references and definition reads remain lower-bound evidence."
                        )
                        : wasTruncated
                            ? "Newest bounded history was scanned. Explicit references and definition reads are lower-bound evidence."
                            : "Best-effort local scan. Explicit skill references and definition reads are lower-bound evidence."
                )
            ]
        } catch ReadOnlyInsightsDatabase.Error.missing {
            artifact.coverage = [unavailable]
        } catch {
            artifact.coverage = [
                ConversationScanCoverage(
                    client: .codex,
                    sourceID: "codex-thread-history-sqlite-v1",
                    sourceName: "Codex local thread history",
                    status: .degraded,
                    detail: "Codex history could not be read safely. No conversation content was retained."
                )
            ]
        }
        return artifact
    }

    private func scanClaudeSQLite(
        homeURL: URL,
        windowStart: Date,
        options: InsightScanOptions
    ) -> ConversationScanArtifact {
        var artifact = ConversationScanArtifact(windowStart: windowStart)
        let databaseURL = homeURL.appending(path: ".claude/__store.db")
        let unavailable = ConversationScanCoverage(
            client: .claude,
            sourceID: "claude-store-sqlite-v1",
            sourceName: "Claude Code local history",
            status: .unavailable,
            detail: "Claude history tracking is unavailable."
        )

        do {
            let database = try ReadOnlyInsightsDatabase(url: databaseURL, containedBy: homeURL)
            let cutoff = windowStart.timeIntervalSince1970
            let queriedConversations = try database.queryConversationIDs(
                sql: """
                    SELECT base_messages.session_id, MAX(base_messages.timestamp)
                    FROM base_messages
                    JOIN user_messages ON user_messages.uuid = base_messages.uuid
                    WHERE base_messages.timestamp >= ?
                    GROUP BY base_messages.session_id
                    ORDER BY MAX(base_messages.timestamp) DESC
                    LIMIT ?
                    """,
                cutoff: cutoff,
                limit: options.maximumConversationsPerClient + 1
            )
            let conversations = Array(queriedConversations.prefix(options.maximumConversationsPerClient))
            var latestItemAt: Date?
            var inspected = 0
            var skipped = 0
            var wasTruncated = queriedConversations.count > options.maximumConversationsPerClient

            for conversation in conversations {
                let queriedRows = try database.queryRows(
                    sql: """
                        SELECT kind, message, timestamp
                        FROM (
                            SELECT 'user' AS kind, user_messages.message AS message,
                                base_messages.timestamp AS timestamp
                            FROM base_messages
                            JOIN user_messages ON user_messages.uuid = base_messages.uuid
                            WHERE base_messages.session_id = ? AND base_messages.timestamp >= ?
                            UNION ALL
                            SELECT 'assistant' AS kind, assistant_messages.message AS message,
                                base_messages.timestamp AS timestamp
                            FROM base_messages
                            JOIN assistant_messages ON assistant_messages.uuid = base_messages.uuid
                            WHERE base_messages.session_id = ? AND base_messages.timestamp >= ?
                            ORDER BY timestamp DESC
                            LIMIT ?
                        )
                        ORDER BY timestamp ASC
                        """,
                    repeatedConversationID: conversation.id,
                    repeatedCutoff: cutoff,
                    limit: options.maximumItemsPerConversation + 1,
                    maximumTextBytes: options.maximumItemBytes
                )
                if queriedRows.count > options.maximumItemsPerConversation { wasTruncated = true }
                let rows = queriedRows.suffix(options.maximumItemsPerConversation)
                for candidate in rows {
                    guard let row = candidate else {
                        skipped += 1
                        continue
                    }
                    let date = row.date(milliseconds: false)
                    latestItemAt = maxDate(latestItemAt, date)
                    guard let object = parseJSONObject(row.payload) else {
                        skipped += 1
                        continue
                    }
                    inspected += 1
                    if row.kind == "user" {
                        if let text = messageText(from: object), !text.isEmpty {
                            artifact.messages.append(
                                .init(
                                    conversationID: conversation.id,
                                    client: .claude,
                                    date: date,
                                    tokens: insightTokens(from: sanitizeConversationText(text))
                                )
                            )
                        }
                    }
                }
            }

            artifact.coverage = [
                ConversationScanCoverage(
                    client: .claude,
                    sourceID: "claude-store-sqlite-v1",
                    sourceName: "Claude Code local history",
                    status: (wasTruncated || skipped > 0) ? .degraded : .scanned,
                    conversationsScanned: conversations.count,
                    itemsInspected: inspected,
                    itemsSkipped: skipped,
                    latestItemAt: latestItemAt,
                    supportsUsageAttribution: false,
                    detail: skipped > 0
                        ? skippedItemDetail(
                            skipped,
                            suffix: "Remaining messages were scanned for recommendations; activation tracking is unavailable."
                        )
                        : wasTruncated
                            ? "Newest bounded messages were scanned for recommendations; activation tracking is unavailable."
                            : "Messages were scanned for recommendations; activation tracking is unavailable from this fallback."
                )
            ]
        } catch ReadOnlyInsightsDatabase.Error.missing {
            artifact.coverage = [unavailable]
        } catch {
            artifact.coverage = [
                ConversationScanCoverage(
                    client: .claude,
                    sourceID: "claude-store-sqlite-v1",
                    sourceName: "Claude Code local history",
                    status: .degraded,
                    detail: "Claude history could not be read safely. No conversation content was retained."
                )
            ]
        }
        return artifact
    }

    private func scanClaudeJSONL(
        homeURL: URL,
        windowStart: Date,
        options: InsightScanOptions,
        skillLookup: SkillNameLookup
    ) -> ConversationScanArtifact {
        var artifact = ConversationScanArtifact(windowStart: windowStart)
        let projectsURL = homeURL.appending(path: ".claude/projects", directoryHint: .isDirectory)
        let queriedFiles = recentJSONLFiles(
            under: projectsURL,
            containedBy: homeURL,
            limit: options.maximumConversationsPerClient + 1
        )
        guard !queriedFiles.isEmpty else {
            artifact.coverage = [
                ConversationScanCoverage(
                    client: .claude,
                    sourceID: "claude-project-jsonl-v1",
                    sourceName: "Claude Code project transcripts",
                    status: .unavailable,
                    detail: "Claude project transcripts were not available."
                )
            ]
            return artifact
        }
        let files = Array(queriedFiles.prefix(options.maximumConversationsPerClient))

        var scannedFiles = 0
        var inspected = 0
        var skipped = 0
        var latestItemAt: Date?
        var hadReadFailure = false
        var wasTruncated = queriedFiles.count > options.maximumConversationsPerClient
        var remainingTranscriptBytes = maximumClaudeTranscriptBytes
        let maximumFileBytes = min(
            16 * 1_024 * 1_024,
            max(options.maximumItemBytes, options.maximumItemBytes * options.maximumItemsPerConversation)
        )

        for file in files {
            guard let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                fileSize >= 0,
                fileSize <= remainingTranscriptBytes
            else {
                wasTruncated = true
                continue
            }
            remainingTranscriptBytes -= fileSize
            guard
                let contents = try? BoundedFileAccess.readUTF8(
                    at: file,
                    maximumBytes: maximumFileBytes,
                    allowSymbolicLink: false
                )
            else {
                hadReadFailure = true
                continue
            }
            scannedFiles += 1
            var currentTurn = "before-first-user"
            let conversationFallback = file.deletingPathExtension().lastPathComponent
            let allLines = contents.split(whereSeparator: \Character.isNewline)
            if allLines.count > options.maximumItemsPerConversation { wasTruncated = true }
            let lines = allLines.suffix(options.maximumItemsPerConversation)
            for (ordinal, line) in lines.enumerated() {
                guard line.utf8.count <= options.maximumItemBytes,
                    let object = parseJSONObject(String(line)),
                    let dictionary = object as? [String: Any],
                    let date = jsonlDate(from: dictionary)
                else {
                    skipped += 1
                    continue
                }
                guard date >= windowStart else { continue }
                inspected += 1
                latestItemAt = maxDate(latestItemAt, date)
                let conversationID =
                    dictionary["sessionId"] as? String
                    ?? dictionary["conversation_uuid"] as? String
                    ?? conversationFallback
                let type = (dictionary["type"] as? String)?.lowercased()
                let message = dictionary["message"] ?? dictionary

                if type == "user" || messageRole(from: message) == "user" {
                    currentTurn = dictionary["uuid"] as? String ?? "\(date.timeIntervalSince1970):\(ordinal)"
                    if let text = messageText(from: message), !text.isEmpty {
                        artifact.messages.append(
                            .init(
                                conversationID: conversationID,
                                client: .claude,
                                date: date,
                                tokens: insightTokens(from: sanitizeConversationText(text))
                            )
                        )
                    }
                } else if type == "assistant" || messageRole(from: message) == "assistant" {
                    collectClaudeAssistantEvidence(
                        object: dictionary,
                        conversationID: conversationID,
                        turnID: currentTurn,
                        date: date,
                        skillLookup: skillLookup,
                        artifact: &artifact
                    )
                }
            }
        }

        artifact.coverage = [
            ConversationScanCoverage(
                client: .claude,
                sourceID: "claude-project-jsonl-v1",
                sourceName: "Claude Code project transcripts",
                status: (hadReadFailure || wasTruncated || skipped > 0) ? .degraded : .scanned,
                conversationsScanned: scannedFiles,
                itemsInspected: inspected,
                itemsSkipped: skipped,
                latestItemAt: latestItemAt,
                supportsUsageAttribution: true,
                detail: hadReadFailure
                    ? "One or more transcripts exceeded safe read limits or changed during scanning and were skipped."
                    : skipped > 0
                        ? skippedItemDetail(
                            skipped,
                            suffix: "Remaining attribution is grouped by session and user turn."
                        )
                        : wasTruncated
                            ? "Newest bounded transcripts were scanned; attribution is grouped by session and user turn."
                            : "Claude transcript attribution is grouped by session and user turn; no transcript content was retained."
            )
        ]
        return artifact
    }
}

struct ConversationScanArtifact: Sendable {
    var windowStart: Date
    var coverage: [ConversationScanCoverage] = []
    var evidence: Set<UsageEvidence> = []
    var messages: [TokenizedConversationMessage] = []

    var hasObservableSource: Bool {
        coverage.contains { $0.status == .scanned || ($0.status == .degraded && $0.itemsInspected > 0) }
    }

    mutating func merge(_ other: Self) {
        coverage.append(contentsOf: other.coverage)
        evidence.formUnion(other.evidence)
        messages.append(contentsOf: other.messages)
    }
}

struct UsageEvidence: Hashable, Sendable {
    enum Precision: Hashable, Sendable {
        case exact
        case inferred
    }

    var key: String
    var skillID: String
    var precision: Precision
    var provenance: SkillUsageProvenance
    var client: ClientKind
    var date: Date

}

struct TokenizedConversationMessage: Sendable {
    var conversationID: String
    var client: ClientKind
    var date: Date
    var tokens: Set<String>
}

private struct SkillNameLookup {
    private var aliases: [String: Set<String>]
    private var skills: [Skill]

    init(skills: [Skill]) {
        self.skills = skills
        var aliases: [String: Set<String>] = [:]
        for skill in skills {
            for candidate in [skill.id, skill.name, skill.displayName] {
                let normalized = normalizeSkillReference(candidate)
                guard !normalized.isEmpty else { continue }
                aliases[normalized, default: []].insert(skill.id)
                if let suffix = normalized.split(separator: ":").last {
                    aliases[String(suffix), default: []].insert(skill.id)
                }
            }
        }
        self.aliases = aliases
    }

    func resolve(_ value: String) -> String? {
        let normalized = normalizeSkillReference(value)
        if let exact = uniqueValue(in: aliases[normalized]) { return exact }
        if let suffix = normalized.split(separator: ":").last,
            let match = uniqueValue(in: aliases[String(suffix)])
        {
            return match
        }
        let pathMatches = Set(
            skills.compactMap { skill -> String? in
                let name = normalizeSkillReference(skill.name)
                return !name.isEmpty && normalized.contains("/\(name)/skill.md") ? skill.id : nil
            })
        return uniqueValue(in: pathMatches)
    }

    private func uniqueValue(in values: Set<String>?) -> String? {
        guard let values, values.count == 1 else { return nil }
        return values.first
    }
}

private func normalizeSkillReference(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "$`\"'"))
        .lowercased()
}

private func collectClaudeAssistantEvidence(
    object: Any,
    conversationID: String,
    turnID: String,
    date: Date,
    skillLookup: SkillNameLookup,
    artifact: inout ConversationScanArtifact
) {
    for name in attributedSkillNames(in: object) {
        guard let skillID = skillLookup.resolve(name) else { continue }
        artifact.evidence.insert(
            UsageEvidence(
                key: "claude:use:\(conversationID):\(turnID):\(skillID)",
                skillID: skillID,
                precision: .exact,
                provenance: .claudeAttribution,
                client: .claude,
                date: date
            )
        )
    }
    for block in toolUseBlocks(in: object) {
        let name = (block["name"] as? String)?.lowercased() ?? ""
        if name == "skill" {
            for reference in possibleSkillNames(in: block["input"]) {
                guard let skillID = skillLookup.resolve(reference) else { continue }
                artifact.evidence.insert(
                    UsageEvidence(
                        key: "claude:use:\(conversationID):\(turnID):\(skillID)",
                        skillID: skillID,
                        precision: .exact,
                        provenance: .claudeSkillToolCall,
                        client: .claude,
                        date: date
                    )
                )
            }
        } else if name == "read" || name == "bash" {
            for text in block["input"].map(allStringValues) ?? [] {
                for skillID in skillDefinitionReferences(in: text, lookup: skillLookup) {
                    artifact.evidence.insert(
                        UsageEvidence(
                            key: "claude:use:\(conversationID):\(turnID):\(skillID)",
                            skillID: skillID,
                            precision: .inferred,
                            provenance: .skillDefinitionRead,
                            client: .claude,
                            date: date
                        )
                    )
                }
            }
        }
    }
}

private func attributedSkillNames(in object: Any) -> [String] {
    var result: [String] = []
    func visit(_ value: Any) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if key.lowercased() == "attributionskill" {
                    result.append(contentsOf: possibleSkillNames(in: nested))
                } else {
                    visit(nested)
                }
            }
        } else if let array = value as? [Any] {
            array.forEach(visit)
        }
    }
    visit(object)
    return result
}

private func toolUseBlocks(in object: Any) -> [[String: Any]] {
    var result: [[String: Any]] = []
    func visit(_ value: Any) {
        if let dictionary = value as? [String: Any] {
            if (dictionary["type"] as? String)?.lowercased() == "tool_use" {
                result.append(dictionary)
            }
            dictionary.values.forEach(visit)
        } else if let array = value as? [Any] {
            array.forEach(visit)
        }
    }
    visit(object)
    return result
}

private func possibleSkillNames(in value: Any?) -> [String] {
    guard let value else { return [] }
    if let string = value as? String { return [string] }
    if let dictionary = value as? [String: Any] {
        let preferredKeys = ["skill", "skill_name", "skillName", "name", "command"]
        let preferred = preferredKeys.compactMap { dictionary[$0] as? String }
        return preferred.isEmpty ? dictionary.values.flatMap(allStringValues) : preferred
    }
    if let array = value as? [Any] { return array.flatMap(allStringValues) }
    return []
}

private func allStringValues(in value: Any) -> [String] {
    if let string = value as? String { return [string] }
    if let dictionary = value as? [String: Any] {
        return dictionary.values.flatMap(allStringValues)
    }
    if let array = value as? [Any] { return array.flatMap(allStringValues) }
    return []
}

private func explicitlyReferencedSkills(in text: String, lookup: SkillNameLookup) -> Set<String> {
    guard
        let expression = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_-])\$([A-Za-z0-9][A-Za-z0-9:_-]*)"#
        )
    else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Set(
        expression.matches(in: text, range: range).compactMap { match in
            guard let referenceRange = Range(match.range(at: 1), in: text) else { return nil }
            return lookup.resolve(String(text[referenceRange]))
        })
}

private func skillDefinitionReferences(in text: String, lookup: SkillNameLookup) -> Set<String> {
    guard text.localizedCaseInsensitiveContains("SKILL.md") else { return [] }
    var result: Set<String> = []
    for segment in text.split(whereSeparator: \Character.isWhitespace) {
        let candidate = String(segment).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{};,"))
        if let skillID = lookup.resolve(candidate) { result.insert(skillID) }
    }
    return result
}

private func commandStrings(from object: Any) -> [String] {
    guard let dictionary = object as? [String: Any], let value = dictionary["command"] else { return [] }
    return allStringValues(in: value)
}

private func messageText(from object: Any) -> String? {
    if let string = object as? String { return string }
    if let dictionary = object as? [String: Any] {
        if let content = dictionary["content"] {
            let values = messageContentStrings(from: content)
            if !values.isEmpty { return values.joined(separator: "\n") }
        }
        if let message = dictionary["message"] {
            return messageText(from: message)
        }
        if let text = dictionary["text"] as? String { return text }
    }
    return nil
}

private func messageContentStrings(from value: Any) -> [String] {
    if let string = value as? String { return [string] }
    if let array = value as? [Any] {
        return array.flatMap { item -> [String] in
            guard let dictionary = item as? [String: Any] else { return [] }
            let type = (dictionary["type"] as? String)?.lowercased()
            guard type == nil || type == "text" || type == "input_text" else { return [] }
            return (dictionary["text"] as? String).map { [$0] } ?? []
        }
    }
    if let dictionary = value as? [String: Any], let text = dictionary["text"] as? String {
        return [text]
    }
    return []
}

private func messageRole(from object: Any) -> String? {
    guard let dictionary = object as? [String: Any] else { return nil }
    return (dictionary["role"] as? String)?.lowercased()
}

private func parseJSONObject(_ text: String) -> Any? {
    guard text.utf8.count <= 1 * 1_024 * 1_024 else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

private func sanitizeConversationText(_ text: String) -> String {
    var result = text
    let containerNames = [
        "app-context", "in-app-browser-context", "environment_context", "system", "developer", "recommended_plugins",
    ]
    for name in containerNames {
        guard
            let expression = try? NSRegularExpression(
                pattern:
                    "(?is)<\(NSRegularExpression.escapedPattern(for: name))\\b[^>]*>.*?</\(NSRegularExpression.escapedPattern(for: name))>"
            )
        else { continue }
        result = expression.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: " "
        )
    }
    result = SensitiveValueRedactor.redact(result)
    if let pathExpression = try? NSRegularExpression(pattern: #"(?i)(?:/Users/|~/)[^\s\"']+"#) {
        result = pathExpression.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "[local-path]"
        )
    }
    return String(result.prefix(2_000))
}

private let insightStopWords: Set<String> = [
    "about", "after", "again", "also", "and", "are", "been", "before", "being", "but", "can", "could", "did", "does",
    "doing", "for", "from", "have", "help", "how", "into", "its", "just", "make", "more", "need", "not", "please", "should",
    "some", "that", "the", "their", "then", "there", "these", "they", "this", "through", "use", "using", "want", "what", "when",
    "where", "which", "with", "would", "you", "your",
]

func insightTokens(from text: String) -> Set<String> {
    let components = text.lowercased().split { !$0.isLetter && !$0.isNumber }
    return Set(
        components.compactMap { component in
            let token = String(component)
            guard token.count >= 3, token.count <= 48, !insightStopWords.contains(token) else { return nil }
            return token
        })
}

private func jsonlDate(from dictionary: [String: Any]) -> Date? {
    if let seconds = dictionary["timestamp"] as? Double { return Date(timeIntervalSince1970: seconds) }
    if let numericTimestamp = dictionary["timestamp"] as? Int {
        let seconds = numericTimestamp > 10_000_000_000 ? Double(numericTimestamp) / 1_000 : Double(numericTimestamp)
        return Date(timeIntervalSince1970: seconds)
    }
    guard let value = dictionary["timestamp"] as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func recentJSONLFiles(under root: URL, containedBy homeURL: URL, limit: Int) -> [URL] {
    let resolvedHome = homeURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    guard isContained(resolvedRoot, by: resolvedHome),
        (try? resolvedRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
    else { return [] }

    var files: [(URL, Date)] = []
    var inspected = 0
    while let file = enumerator.nextObject() as? URL, inspected < 10_000 {
        inspected += 1
        let relativePath = file.path(percentEncoded: false).replacingOccurrences(
            of: resolvedRoot.path(percentEncoded: false),
            with: ""
        )
        guard file.pathExtension.lowercased() == "jsonl",
            file.lastPathComponent != "skill-injections.jsonl",
            !relativePath.split(separator: "/").contains("subagents"),
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            isContained(file.resolvingSymlinksInPath().standardizedFileURL, by: resolvedRoot)
        else { continue }
        files.append((file, values.contentModificationDate ?? .distantPast))
    }
    return files.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.path < rhs.0.path
    }.prefix(limit).map(\.0)
}

private func isContained(_ child: URL, by root: URL) -> Bool {
    let rootPath = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let childPath = child.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
}

private func skippedItemDetail(_ count: Int, suffix: String) -> String {
    "\(count) malformed or oversized transcript item\(count == 1 ? " was" : "s were") skipped. \(suffix)"
}

private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
    guard let lhs else { return rhs }
    return max(lhs, rhs)
}

private struct DatabaseConversation {
    var id: String
    var timestamp: Double
}

private struct DatabaseRow {
    var kind: String
    var payload: String
    var timestamp: Double
    var turnID: String?

    func date(milliseconds: Bool) -> Date {
        Date(timeIntervalSince1970: milliseconds ? timestamp / 1_000 : timestamp)
    }
}

private final class ReadOnlyInsightsDatabase {
    enum Error: Swift.Error {
        case missing
        case unsafePath
        case open
        case query
    }

    private var handle: OpaquePointer?

    init(url: URL, containedBy homeURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { throw Error.missing }
        let directValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let resolvedHome = homeURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard directValues.isRegularFile == true,
            directValues.isSymbolicLink != true,
            directValues.fileSize.map({ $0 >= 0 && $0 <= 8 * 1_024 * 1_024 * 1_024 }) == true,
            isContained(resolvedURL, by: resolvedHome)
        else { throw Error.unsafePath }

        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                resolvedURL.path(percentEncoded: false),
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK, let database
        else {
            if database != nil { sqlite3_close(database) }
            throw Error.open
        }
        handle = database
        guard sqlite3_busy_timeout(database, 1_000) == SQLITE_OK,
            sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(database)
            handle = nil
            throw Error.open
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func queryConversationIDs(sql: String, cutoff: Double, limit: Int) throws -> [DatabaseConversation] {
        guard let handle else { throw Error.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            sqlite3_bind_double(statement, 1, cutoff) == SQLITE_OK,
            sqlite3_bind_int64(statement, 2, Int64(limit)) == SQLITE_OK
        else { throw Error.query }
        var result: [DatabaseConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = boundedText(statement, column: 0, maximumBytes: 8 * 1_024) else { continue }
            result.append(.init(id: id, timestamp: sqlite3_column_double(statement, 1)))
        }
        guard sqlite3_errcode(handle) == SQLITE_OK || sqlite3_errcode(handle) == SQLITE_DONE else { throw Error.query }
        return result
    }

    func queryRows(
        sql: String,
        conversationID: String,
        cutoff: Double,
        limit: Int,
        maximumTextBytes: Int
    ) throws -> [DatabaseRow?] {
        try queryRows(
            sql: sql,
            bindings: [.text(conversationID), .double(cutoff), .integer(limit)],
            maximumTextBytes: maximumTextBytes
        )
    }

    func queryRows(
        sql: String,
        repeatedConversationID: String,
        repeatedCutoff: Double,
        limit: Int,
        maximumTextBytes: Int
    ) throws -> [DatabaseRow?] {
        try queryRows(
            sql: sql,
            bindings: [
                .text(repeatedConversationID), .double(repeatedCutoff),
                .text(repeatedConversationID), .double(repeatedCutoff), .integer(limit),
            ],
            maximumTextBytes: maximumTextBytes
        )
    }

    private enum Binding {
        case text(String)
        case double(Double)
        case integer(Int)
    }

    private func queryRows(sql: String, bindings: [Binding], maximumTextBytes: Int) throws -> [DatabaseRow?] {
        guard let handle else { throw Error.open }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Error.query }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, insightsSQLiteTransient)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, Int64(value))
            }
            guard result == SQLITE_OK else { throw Error.query }
        }

        var rows: [DatabaseRow?] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = boundedText(statement, column: 0, maximumBytes: 256),
                let payload = boundedText(statement, column: 1, maximumBytes: maximumTextBytes)
            else {
                rows.append(nil)
                continue
            }
            let turnID =
                sqlite3_column_count(statement) > 3
                ? boundedText(statement, column: 3, maximumBytes: 8 * 1_024)
                : nil
            rows.append(
                DatabaseRow(
                    kind: kind,
                    payload: payload,
                    timestamp: sqlite3_column_double(statement, 2),
                    turnID: turnID
                )
            )
        }
        guard sqlite3_errcode(handle) == SQLITE_OK || sqlite3_errcode(handle) == SQLITE_DONE else { throw Error.query }
        return rows
    }

    private func boundedText(_ statement: OpaquePointer?, column: Int32, maximumBytes: Int) -> String? {
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0, byteCount <= maximumBytes,
            let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: byteCount), encoding: .utf8)
    }
}
