import Foundation

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

        guard !Task.isCancelled else { return artifact }

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
        guard !Task.isCancelled else { return artifact }
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
        guard !Task.isCancelled else { return artifact }
        if options.clients.contains(.kiro) {
            artifact.merge(scanKiro(homeURL: homeURL, windowStart: windowStart, options: options, skillLookup: lookup))
        }

        return artifact
    }

    /// Kiro CLI keeps one `<id>.jsonl` per chat session, each line one item:
    /// `Prompt` for the person, `AssistantMessage` for the model (with its tool
    /// uses), `ToolResults` for what came back. A sibling `<id>.json` names the
    /// session and its working directory.
    private func scanKiro(
        homeURL: URL,
        windowStart: Date,
        options: InsightScanOptions,
        skillLookup: SkillNameLookup
    ) -> ConversationScanArtifact {
        var artifact = ConversationScanArtifact(windowStart: windowStart)
        let kiroHome: URL
        if let configured = ProcessInfo.processInfo.environment["KIRO_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            kiroHome = URL(filePath: configured, directoryHint: .isDirectory)
        } else {
            kiroHome = homeURL.appending(path: ".kiro", directoryHint: .isDirectory)
        }
        let sessionsURL = kiroHome.appending(path: "sessions/cli", directoryHint: .isDirectory)
        let queriedFiles = recentJSONLFiles(
            under: sessionsURL, containedBy: homeURL, limit: options.maximumConversationsPerClient + 1)
        guard !queriedFiles.isEmpty else {
            artifact.coverage = [
                ConversationScanCoverage(
                    client: .kiro, sourceID: "kiro-cli-sessions-jsonl-v1", sourceName: "Kiro CLI chat sessions",
                    status: .unavailable, detail: "Kiro CLI chat sessions were not available.")
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
            16 * 1_024 * 1_024, max(options.maximumItemBytes, options.maximumItemBytes * options.maximumItemsPerConversation))

        for file in files {
            if Task.isCancelled { break }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumFileBytes,
                size <= remainingTranscriptBytes
            else {
                hadReadFailure = true
                continue
            }
            remainingTranscriptBytes -= size
            guard let contents = try? BoundedFileAccess.readUTF8(at: file, maximumBytes: maximumFileBytes, allowSymbolicLink: false)
            else {
                hadReadFailure = true
                continue
            }
            let conversationID = file.deletingPathExtension().lastPathComponent
            var digest = ConversationDigestBuilder(conversationID: conversationID, client: .kiro)
            // The sibling metadata file names the session. It is small and its
            // absence is fine; the transcript stands on its own.
            let metadataURL = file.deletingPathExtension().appendingPathExtension("json")
            if let metadataText = try? BoundedFileAccess.readUTF8(at: metadataURL, maximumBytes: 64 * 1_024, allowSymbolicLink: false),
                let metadata = parseJSONObject(metadataText) as? [String: Any]
            {
                digest.title = metadata["title"] as? String
                digest.workingDirectory = metadata["cwd"] as? String
            }
            let allLines = contents.split(whereSeparator: \Character.isNewline)
            if allLines.count > options.maximumItemsPerConversation { wasTruncated = true }
            var sawItemInWindow = false
            var currentTurn = "before-first-prompt"
            for (ordinal, line) in allLines.suffix(options.maximumItemsPerConversation).enumerated() {
                if Task.isCancelled { break }
                guard line.utf8.count <= options.maximumItemBytes,
                    let object = parseJSONObject(String(line)) as? [String: Any],
                    let kind = object["kind"] as? String,
                    let data = object["data"] as? [String: Any]
                else {
                    skipped += 1
                    continue
                }
                let date = ((data["meta"] as? [String: Any])?["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    ?? Date.distantPast
                guard date >= windowStart else { continue }
                sawItemInWindow = true
                inspected += 1
                latestItemAt = maxDate(latestItemAt, date)
                let texts = ((data["content"] as? [[String: Any]]) ?? []).compactMap { block -> String? in
                    guard block["kind"] as? String == "text" else { return nil }
                    return block["data"] as? String
                }
                switch kind {
                case "Prompt":
                    currentTurn = data["message_id"] as? String ?? "\(date.timeIntervalSince1970):\(ordinal)"
                    let text = texts.joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    artifact.messages.append(
                        .init(conversationID: conversationID, client: .kiro, date: date,
                              tokens: insightTokens(from: sanitizeConversationText(text))))
                    digest.noteUserMessage(text, at: date)
                    // Kiro invokes a skill as a slash command in the prompt.
                    for reference in slashSkillReferences(in: text) {
                        digest.noteSkill(reference, at: date)
                        if let skillID = skillLookup.resolve(reference) {
                            artifact.evidence.insert(
                                UsageEvidence(
                                    key: "kiro:use:\(conversationID):\(currentTurn):\(skillID)", skillID: skillID,
                                    precision: .exact, provenance: .kiroSlashCommand, client: .kiro, date: date))
                        }
                    }
                case "AssistantMessage":
                    for block in (data["content"] as? [[String: Any]]) ?? [] where block["kind"] as? String == "tool_use" {
                        guard let use = block["data"] as? [String: Any], let name = use["name"] as? String else { continue }
                        digest.noteTool(name, at: date)
                    }
                default:
                    continue
                }
            }
            if sawItemInWindow {
                scannedFiles += 1
                if let built = digest.digest { artifact.digests.append(built) }
            }
        }

        artifact.coverage = [
            ConversationScanCoverage(
                client: .kiro, sourceID: "kiro-cli-sessions-jsonl-v1", sourceName: "Kiro CLI chat sessions",
                status: (hadReadFailure || wasTruncated || skipped > 0) ? .degraded : .scanned,
                conversationsScanned: scannedFiles, itemsInspected: inspected, itemsSkipped: skipped,
                latestItemAt: latestItemAt, supportsUsageAttribution: true,
                detail: hadReadFailure
                    ? "One or more sessions exceeded safe read limits and were skipped."
                    : wasTruncated
                        ? "Newest bounded sessions were scanned; a skill is attributed when a prompt invokes it as a slash command."
                        : "A skill is attributed when a prompt invokes it as a slash command; no session content was retained.")
        ]
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
                if Task.isCancelled { break }
                var digest = ConversationDigestBuilder(conversationID: conversation.id, client: .codex)
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
                    if Task.isCancelled { break }
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
                            digest.noteUserMessage(text, at: row.date(milliseconds: true))
                            for reference in dollarSkillReferences(in: text) { digest.noteSkill(reference, at: row.date(milliseconds: true)) }
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
                    case "mcpToolCall":
                        if let dictionary = object as? [String: Any] {
                            let server = dictionary["server"] as? String ?? ""
                            let tool = dictionary["tool"] as? String ?? ""
                            let name = [server, tool].filter { !$0.isEmpty }.joined(separator: "/")
                            if !name.isEmpty { digest.noteTool(name, at: row.date(milliseconds: true)) }
                        }
                    case "commandExecution":
                        digest.noteTool("shell", at: row.date(milliseconds: true))
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
                if let built = digest.digest { artifact.digests.append(built) }
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
                if Task.isCancelled { break }
                var digest = ConversationDigestBuilder(conversationID: conversation.id, client: .codex)
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
                    if Task.isCancelled { break }
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
            if Task.isCancelled { break }
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
            var digest = ConversationDigestBuilder(conversationID: conversationFallback, client: .claude)
            let allLines = contents.split(whereSeparator: \Character.isNewline)
            if allLines.count > options.maximumItemsPerConversation { wasTruncated = true }
            let lines = allLines.suffix(options.maximumItemsPerConversation)
            for (ordinal, line) in lines.enumerated() {
                if Task.isCancelled { break }
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
                if digest.workingDirectory == nil, let cwd = dictionary["cwd"] as? String { digest.workingDirectory = cwd }
                let type = (dictionary["type"] as? String)?.lowercased()
                let message = dictionary["message"] ?? dictionary

                if type == "user" || messageRole(from: message) == "user" {
                    currentTurn = dictionary["uuid"] as? String ?? "\(date.timeIntervalSince1970):\(ordinal)"
                    // A tool result comes back as a user-role item; it is the
                    // tool speaking, not the person, and is not their message.
                    let isToolResult = (message as? [String: Any]).map { isToolResultContent($0["content"]) } ?? false
                    if !isToolResult, let text = messageText(from: message), !text.isEmpty {
                        artifact.messages.append(
                            .init(
                                conversationID: conversationID,
                                client: .claude,
                                date: date,
                                tokens: insightTokens(from: sanitizeConversationText(text))
                            )
                        )
                        digest.noteUserMessage(text, at: date)
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
                    for block in toolUseBlocks(in: dictionary) {
                        guard let name = block["name"] as? String else { continue }
                        digest.noteTool(name, at: date)
                        if name.lowercased() == "skill" {
                            for reference in possibleSkillNames(in: block["input"]) { digest.noteSkill(reference, at: date) }
                        }
                    }
                }
            }
            if let built = digest.digest { artifact.digests.append(built) }
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
    /// One bounded, redacted digest per conversation, for the deep dive. Kept
    /// only in this in-memory artifact and in the prompt sent to the person's
    /// own assistant; never in the saved report.
    var digests: [ConversationDigest] = []

    var hasObservableSource: Bool {
        coverage.contains { $0.status == .scanned || ($0.status == .degraded && $0.itemsInspected > 0) }
    }

    mutating func merge(_ other: Self) {
        coverage.append(contentsOf: other.coverage)
        evidence.formUnion(other.evidence)
        messages.append(contentsOf: other.messages)
        digests.append(contentsOf: other.digests)
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

/// Not `private`: `SkillNameLookup` moved to its own file and normalises
/// references through this helper.
func normalizeSkillReference(_ value: String) -> String {
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

/// Whether a user-role item's content is a tool result rather than something
/// the person typed. Claude Code records tool results as user items.
private func isToolResultContent(_ content: Any?) -> Bool {
    guard let blocks = content as? [Any], !blocks.isEmpty else { return false }
    return blocks.allSatisfy { ($0 as? [String: Any])?["type"] as? String == "tool_result" }
}

/// The `/name` slash commands at the start of a Kiro prompt or a line in it.
private func slashSkillReferences(in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"(?m)^\s*/([a-z0-9][a-z0-9_.:-]{1,63})\b"#, options: [.caseInsensitive])
    else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
}

/// The `$name` skill invocations in a Codex message.
private func dollarSkillReferences(in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"(?<![\w$])\$([a-z0-9][a-z0-9_.-]{1,63})"#, options: [.caseInsensitive])
    else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
}

private func messageRole(from object: Any) -> String? {
    guard let dictionary = object as? [String: Any] else { return nil }
    return (dictionary["role"] as? String)?.lowercased()
}

private func parseJSONObject(_ text: String) -> Any? {
    guard text.utf8.count <= 1 * 1_024 * 1_024 else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

/// Not `private`: `ConversationDigestBuilder` moved to its own file and
/// redacts its strings through this helper.
func sanitizeConversationText(_ text: String) -> String {
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

/// Shared by the scanner and the read-only SQLite reader to keep every path
/// inside the home root. Not `private`: `ReadOnlyInsightsDatabase` lives in its
/// own file and calls this.
func isContained(_ child: URL, by root: URL) -> Bool {
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
