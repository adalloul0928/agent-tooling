import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A setup service that answers from memory: no shell is asked for its PATH,
/// no assistant is run, and the kept checkup lives in this object.
final class StubSetupServices: SetupServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: SetupCheckup?
    private var answer: Result<SetupReview, any Error>?
    private var reviews: [(client: ClientKind, purpose: SetupReviewPrompt.Purpose, focus: ClientKind?, releaseNotes: Int)] = []
    private let holdFor: Duration?

    /// `review` scripts the assistant's answer; nil means it cannot be reached.
    init(restored: SetupCheckup? = nil, review: Result<SetupReview, any Error>? = nil, holdFor: Duration? = nil) {
        kept = restored
        answer = review
        self.holdFor = holdFor
    }

    var reviewCalls: [(client: ClientKind, purpose: SetupReviewPrompt.Purpose, focus: ClientKind?, releaseNotes: Int)] {
        lock.withLock { reviews }
    }
    var keptCheckup: SetupCheckup? { lock.withLock { kept } }

    func searchPath(homeURL: URL) async -> [URL] { [] }

    func review(
        client: ClientKind, purpose: SetupReviewPrompt.Purpose, audit: SetupAuditReport, digests: [ConversationDigest],
        focus: ClientKind?, clientVersions: [ClientKind: String], releaseNotes: [String]
    ) async throws -> SetupReview {
        let answer = lock.withLock {
            reviews.append((client, purpose, focus, releaseNotes.count))
            return self.answer
        }
        if let holdFor { try await Task.sleep(for: holdFor) }
        guard let answer else { throw SetupReviewError.unsupportedClient(client) }
        return try answer.get()
    }

    func lastCheckup() -> SetupCheckup? { lock.withLock { kept } }
    func keep(_ checkup: SetupCheckup) throws { lock.withLock { kept = checkup } }

    /// Scripted notes per client; a client not listed has none to fetch.
    var notes: [ClientKind: Result<[ClientReleaseNote], any Error>] = [:]
    private var keptClientReviews: [ClientKind: ClientReview] = [:]

    func releaseNotes(for client: ClientKind, installedVersion: String?) async throws -> [ClientReleaseNote] {
        guard let scripted = lock.withLock({ notes[client] }) else { throw ClientReleaseNotesError.unsupportedClient(client) }
        return try scripted.get()
    }
    func lastClientReviews() -> [ClientKind: ClientReview] { lock.withLock { keptClientReviews } }
    func keep(clientReviews: [ClientKind: ClientReview]) throws { lock.withLock { keptClientReviews = clientReviews } }
    var keptClientReview: (ClientKind) -> ClientReview? { { client in self.lock.withLock { self.keptClientReviews[client] } } }
}

extension ShellRenderFixture {
    /// A review as Claude Code would answer one: a summary and two
    /// recommendations, one grounded in a finding and one the assistant read.
    static func setupReview(over audit: SetupAuditReport, at generatedAt: Date = .now) -> SetupReview {
        let finding = audit.findings.first
        return SetupReview(
            generatedAt: generatedAt, client: .claude, auditGeneratedAt: audit.generatedAt,
            summary: "Two things need attention; the rest is tidy.",
            recommendations: [
                SetupRecommendation(
                    id: "review:claudecode:0:remove", category: .cleanup, title: "Remove the dead link", summary: "It points at nothing.",
                    rationale: "Claude Code skips it.", client: .claude, priority: 1,
                    provenance: finding.map { .audit(findingID: $0.id) } ?? .opinion,
                    action: finding?.actions.first.map { .take($0) } ?? .readOnly, findingIDs: finding.map { [$0.id] } ?? []),
                SetupRecommendation(
                    id: "review:claudecode:1:setting", category: .settings, title: "Turn on tool search", summary: "Fewer tokens per turn.",
                    rationale: "The docs recommend it for many MCP servers.", client: .claude, priority: 10,
                    provenance: .investigated(source: "~/.claude/settings.json"),
                    action: .setSetting(client: .claude, key: "toolSearch", value: "true"), findingIDs: []),
            ])
    }

    /// A checkup with one finding of each severity, over this fixture's home.
    static func setupCheckup(home: URL, review: Bool = true) -> SetupCheckup {
        let audit = SetupAuditReport(
            clients: [.claude, .codex],
            findings: [
                SetupFinding(
                    kind: .brokenSkillLink, severity: .medium, client: .claude, subject: "gone", title: "gone points at nothing",
                    detail: "The entry is a link to a folder that is no longer there.", evidence: ["~/.claude/skills/gone"],
                    actions: [
                        .removeBrokenLink(path: home.appending(path: ".claude/skills/gone").path(percentEncoded: false), client: .claude)
                    ]),
                SetupFinding(
                    kind: .unmanagedSkill, severity: .info, client: .claude, subject: "docx", title: "docx is not managed by this app",
                    detail: "Claude Code has this skill, but the library holds no copy.", evidence: ["~/.claude/skills/docx"],
                    actions: [
                        .adoptSkill(path: home.appending(path: ".claude/skills/docx").path(percentEncoded: false), client: .claude),
                        .removeSkillCopy(path: home.appending(path: ".claude/skills/docx").path(percentEncoded: false), client: .claude),
                    ]),
                SetupFinding(
                    kind: .missingPluginInstall, severity: .high, client: .codex, subject: "gone@aim",
                    title: "Gone is listed but its files are gone",
                    detail: "Codex records this plugin at a folder that does not exist.", evidence: ["~/.codex/plugins/cache/aim/gone/1.0"],
                    actions: [.reinstallPlugin(pluginID: "gone@aim", client: .codex)]),
            ],
            counts: [.claude: .init(skills: 12, plugins: 3, mcpServers: 4), .codex: .init(skills: 5, plugins: 2, mcpServers: 4)])
        return SetupCheckup(audit: audit, review: review ? setupReview(over: audit) : nil)
    }
}
