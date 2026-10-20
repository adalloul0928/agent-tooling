import Foundation
import Testing

@testable import AgentToolingCore

/// What the weekly review may read, held to what Let your assistant help says
/// about it: the tooling folders in the app order, anchored at the root so
/// Claude Code reads them as absolute; every conversation store inside them
/// denied; and
/// Claude Code run from an empty request folder.
@Suite("Setup review read scope")
struct SetupReviewReadScopeTests {
    private let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    private func allowed(_ shape: [String]) throws -> [String] {
        let start = try #require(shape.firstIndex(of: "--allowedTools"))
        let end = try #require(shape.firstIndex(of: "--disallowedTools"))
        return Array(shape[(start + 1)..<end])
    }

    private func disallowed(_ shape: [String]) throws -> [String] {
        let start = try #require(shape.firstIndex(of: "--disallowedTools"))
        return Array(shape[(start + 1)...])
    }

    private var policy: OperationCommandPolicy {
        OperationCommandPolicy(
            libraryURL: home.appending(path: "library"), gitBackupRoot: home.appending(path: "backup"), homeURL: home)
    }

    // MARK: Allow rules

    @Test func theAllowRulesAreAbsoluteAndInTheAppOrder() throws {
        for web in [false, true] {
            let reads = try allowed(SetupReviewCommandShapes.claude(homeURL: home, web: web)).filter { $0.hasPrefix("Read(") }
            #expect(
                reads == [
                    "Read(//Users/example/.codex/**)", "Read(//Users/example/.agents/**)", "Read(//Users/example/.claude/**)",
                    "Read(//Users/example/.gemini/**)", "Read(//Users/example/.kiro/**)",
                ])
        }
        #expect(SetupReviewCommandShapes.readableFolders == [".codex", ".agents", ".claude", ".gemini", ".kiro"])
    }

    /// A rule with one leading slash is anchored at Claude Code's working
    /// directory and silently matches nothing; none of the shapes has one.
    @Test func noReadRuleHasASingleLeadingSlash() throws {
        for web in [false, true] {
            let rules = SetupReviewCommandShapes.claude(homeURL: home, web: web).filter { $0.hasPrefix("Read(") }
            #expect(!rules.isEmpty)
            #expect(rules.allSatisfy { $0.hasPrefix("Read(//") && !$0.hasPrefix("Read(///") }, "\(rules)")
        }
    }

    @Test func aHomeWrittenWithATrailingSlashGivesTheSameRules() {
        let slashed = URL(filePath: "/Users/example/", directoryHint: .isDirectory)
        #expect(SetupReviewCommandShapes.claude(homeURL: slashed, web: false) == SetupReviewCommandShapes.claude(homeURL: home, web: false))
    }

    // MARK: Deny rules

    /// Every place inside the readable folders where an app keeps what was
    /// said, typed, pasted, dictated or attached is denied: the transcripts,
    /// the archived ones, each app's typed history (and its rotated copies),
    /// the session indexes, what was pasted, the edited files' snapshots,
    /// attachments and dictation.
    @Test func everyConversationStoreIsDeniedInBothShapes() throws {
        for web in [false, true] {
            let denied = try disallowed(SetupReviewCommandShapes.claude(homeURL: home, web: web))
            for rule in [
                "Read(//Users/example/.claude/projects/**)", "Read(//Users/example/.codex/sessions/**)",
                "Read(//Users/example/.kiro/sessions/**)", "Read(//Users/example/.kiro/session-index/**)",
                "Read(//Users/example/.codex/archived_sessions/**)", "Read(//Users/example/.codex/attachments/**)",
                "Read(//Users/example/.codex/dictation-history/**)", "Read(//Users/example/.claude/sessions/**)",
                "Read(//Users/example/.claude/file-history/**)", "Read(//Users/example/.claude/paste-cache/**)",
                "Read(//Users/example/.codex/thread_history_1.sqlite*)", "Read(//Users/example/.claude/__store.db*)",
                "Read(//Users/example/.codex/history.jsonl*)", "Read(//Users/example/.claude/history.jsonl*)",
                "Read(//Users/example/.codex/session_index.jsonl*)",
                "Read(//Users/example/.codex/transcription-history.jsonl*)",
            ] {
                #expect(denied.contains(rule), "\(rule) is not denied when web is \(web)")
            }
            #expect(
                denied.filter { $0.hasPrefix("Read(") } == SetupReviewCommandShapes.withheldRules(homeURL: home),
                "nothing denied that the list does not name")
            #expect(denied.contains("Bash") && denied.contains("Write"), "the tools stay denied beside the paths")
        }
    }

    /// Every withheld place is inside a folder the review may read: a rule
    /// for anywhere else would deny nothing that was allowed.
    @Test func everyWithheldPlaceIsInsideAReadableFolder() {
        let readable = Set(SetupReviewCommandShapes.readableFolders)
        for place in SetupReviewCommandShapes.withheldFolders + SetupReviewCommandShapes.withheldFiles {
            #expect(place.split(separator: "/").first.map { readable.contains(String($0)) } == true, "\(place)")
        }
    }

    /// The scanner reads Codex's history from its database and Claude Code's
    /// from its store and its projects folder: each of those is withheld, so
    /// the review cannot read what the scanner reads.
    @Test func whatTheScannerReadsIsWhatTheReviewIsDenied() {
        let withheld = Set(SetupReviewCommandShapes.withheldFolders + SetupReviewCommandShapes.withheldFiles)
        #expect(withheld.isSuperset(of: [".codex/thread_history_1.sqlite", ".claude/__store.db", ".claude/projects", ".kiro/sessions"]))
        #expect(SetupReviewCommandShapes.namedWithheldFolders == [".claude/projects", ".codex/sessions"])
    }

    // MARK: The policy

    @Test func thePolicyRefusesAShapeWithoutItsDenyRules() throws {
        let shape = SetupReviewCommandShapes.claude(homeURL: home, web: false)
        let rules = SetupReviewCommandShapes.withheldRules(homeURL: home)
        #expect(throws: Never.self) { try policy.validate(executable: "claude", arguments: shape) }

        let noDenial = shape.filter { !rules.contains($0) }
        #expect(noDenial.count == shape.count - rules.count)
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: noDenial) }

        var oneMissing = shape
        oneMissing.removeAll { $0 == "Read(//Users/example/.codex/sessions/**)" }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: oneMissing) }
    }

    @Test func thePolicyRefusesTheSingleSlashForm() throws {
        let shape = SetupReviewCommandShapes.claude(homeURL: home, web: false)
        let singleSlash = shape.map { $0.replacingOccurrences(of: "Read(//", with: "Read(/") }
        #expect(singleSlash != shape)
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: singleSlash) }

        // Only the deny rules written the old way: still refused.
        let rules = Set(SetupReviewCommandShapes.withheldRules(homeURL: home))
        let singleSlashDenial = shape.map { rules.contains($0) ? $0.replacingOccurrences(of: "Read(//", with: "Read(/") : $0 }
        #expect(throws: OperationEngineError.self) { try policy.validate(executable: "claude", arguments: singleSlashDenial) }
    }

    // MARK: The service

    @Test func claudeReviewsFromItsEmptyRequestFolderAndCodexFromHome() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupReviewReadScope-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["claude", "codex"] {
            let tool = root.appending(path: ".local/bin/\(name)")
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        }
        let staging = root.appending(path: "Library/Caches/staging", directoryHint: .isDirectory)
        let audit = SetupAuditReport(clients: [.claude, .codex], findings: [], counts: [:])

        let claudeAnswer = #"{"type":"result","is_error":false,"structured_output":{"summary":"Fine.","recommendations":[]}}"#
        let claudeRunner = DirectoryRecordingRunner(output: .init(status: 0, standardOutput: claudeAnswer, standardError: ""))
        _ = try await SetupReviewService(stagingRootURL: staging, homeURL: root, runner: claudeRunner).run(
            client: .claude, purpose: .checkup, audit: audit, digests: [], focus: nil, clientVersions: [:])
        let claudeDirectory = try #require(await claudeRunner.directories.first ?? nil)
        #expect(claudeDirectory.lastPathComponent.hasPrefix("request-"))
        #expect(claudeDirectory.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL)

        let codexEvents = """
            {"type":"item.completed","item":{"id":"b","type":"agent_message","text":"{\\"summary\\":\\"Fine.\\",\\"recommendations\\":[]}"}}

            """
        let codexRunner = DirectoryRecordingRunner(output: .init(status: 0, standardOutput: codexEvents, standardError: ""))
        _ = try await SetupReviewService(stagingRootURL: staging, homeURL: root, runner: codexRunner).run(
            client: .codex, purpose: .checkup, audit: audit, digests: [], focus: nil, clientVersions: [:])
        #expect(try #require(await codexRunner.directories.first ?? nil) == root)
    }

    /// The review run as the app runs it, with its own runner: the child's
    /// `HOME` is the home the review was built for, never this Mac's real one,
    /// and Claude Code starts in the empty request folder.
    @Test func theReviewsOwnRunnerGivesItsHomeAndItsRequestFolder() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "SetupReviewRunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appending(path: "seen.txt")
        let tool = root.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        let answer = #"{"type":"result","is_error":false,"structured_output":{"summary":"Fine.","recommendations":[]}}"#
        // It reads the prompt first, so the runner's write never meets a
        // closed pipe, then says where it ran and as whom.
        let script = """
            #!/bin/sh
            cat > /dev/null
            printf '%s\\n%s\\n' "$HOME" "$(pwd -P)" > '\(record.path(percentEncoded: false))'
            printf '%s' '\(answer)'

            """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        let staging = root.appending(path: "Library/Caches/staging", directoryHint: .isDirectory)

        let review = try await SetupReviewService(stagingRootURL: staging, homeURL: root).run(
            client: .claude, purpose: .checkup, audit: SetupAuditReport(clients: [.claude], findings: [], counts: [:]), digests: [],
            focus: nil, clientVersions: [:])

        #expect(review.summary == "Fine.")
        let seen = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(seen.first == ProcessCommandRunner.plainPath(of: root), "HOME is the review's home")
        let directory = URL(filePath: try #require(seen.last), directoryHint: .isDirectory)
        #expect(directory.lastPathComponent.hasPrefix("request-"))
        #expect(directory.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL)
    }

    // MARK: The prompt

    @Test func theReviewIsHandedAtMostItsLimitOfSummariesAndToldToLeaveHistoryAlone() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let digests = (0..<(SetupReviewPrompt.maximumDigests + 10)).map { index in
            ConversationDigest(
                conversationID: "c\(index)", client: .codex, startedAt: start, endedAt: start.addingTimeInterval(Double(index)),
                userMessages: ["ask \(index)"], userMessageCount: 1, toolsUsed: [], skillsUsed: [])
        }
        let prompt = SetupReviewPrompt.render(
            purpose: .checkup, audit: SetupAuditReport(clients: [.codex], findings: [], counts: [:]), digests: digests, focus: nil,
            clientVersions: [:])
        let lines = prompt.split(separator: "\n").filter { $0.hasPrefix("- Codex") }
        #expect(lines.count == SetupReviewPrompt.maximumDigests)
        #expect(SetupReviewPrompt.maximumDigests == 40)
        #expect(prompt.contains("do not read the conversation history inside them"))
        for place in SetupReviewCommandShapes.withheldFolders + SetupReviewCommandShapes.withheldFiles {
            #expect(prompt.contains(place), "the prompt does not name \(place)")
        }
    }

    @Test func theDeepDiveNamesOnlyTheAppsItsSummariesComeFrom() {
        func digest(_ client: ClientKind) -> ConversationDigest {
            ConversationDigest(
                conversationID: UUID().uuidString, client: client, startedAt: .now, endedAt: .now, userMessages: ["ask"],
                userMessageCount: 1, toolsUsed: [], skillsUsed: [])
        }
        func uses(_ clients: [ClientKind]) -> String {
            InsightsDeepDivePrompt.render(digests: clients.map(digest), skills: [], windowStart: .now, now: .now).prompt
        }
        #expect(uses([.claude, .codex]).contains("The person uses Codex and Claude Code."))
        #expect(uses([.claude]).contains("The person uses Claude Code."))
        #expect(uses([.kiro, .codex, .claude]).contains("The person uses Codex, Claude Code, and Kiro CLI."))
        #expect(!uses([.codex]).contains("Kiro CLI"))
    }

    // MARK: What the copy quotes

    @Test func theLimitsTheCopyQuotesAreTheOnesTheRunsUse() {
        #expect(AssistantRunLimits.reviewDigests == SetupReviewPrompt.maximumDigests)
        #expect(AssistantRunLimits.deepDiveDigests == InsightsDeepDivePrompt.maximumDigests)
        #expect(AssistantRunLimits.messagesPerDigest == ConversationDigestBuilder.maximumUserMessages)
        #expect(AssistantRunLimits.charactersPerMessage == ConversationDigestBuilder.maximumUserMessageCharacters)
        #expect(AssistantRunLimits.lookbackDays == InsightScanOptions().lookbackDays)
        #expect(AssistantRunLimits.historyClients == [.codex, .claude, .kiro])
        #expect(AssistantRunLimits.reviewFolders == SetupReviewCommandShapes.readableFolders)
        #expect(AssistantRunLimits.namedWithheldFolders == SetupReviewCommandShapes.namedWithheldFolders)
    }
}

/// A runner that answers once and remembers the folder each run started in.
private actor DirectoryRecordingRunner: StandardInputCommandRunning {
    private let output: CommandOutput
    private(set) var directories: [URL?] = []

    init(output: CommandOutput) {
        self.output = output
    }

    func run(executable: String, arguments: [String], standardInput: Data, currentDirectory: URL?) async throws -> CommandOutput {
        directories.append(currentDirectory)
        return output
    }
}
