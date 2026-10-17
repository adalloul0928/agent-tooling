import Foundation

/// Builds one conversation's digest as its items stream past: the first few
/// things the person asked, the tools and skills that answered, and where the
/// work happened. Every string is redacted the way the token pass redacts it,
/// and every list is capped, so the digest is short enough to send in bulk and
/// carries no secret or home path.
struct ConversationDigestBuilder {
    static let maximumUserMessages = 4
    static let maximumUserMessageCharacters = 400
    static let maximumTools = 12

    let conversationID: String
    let client: ClientKind
    var startedAt: Date?
    var endedAt: Date?
    var title: String?
    var workingDirectory: String?
    private var userMessages: [String] = []
    private var userMessageCount = 0
    private var tools: [String] = []
    private var skills: Set<String> = []

    init(conversationID: String, client: ClientKind) {
        self.conversationID = conversationID
        self.client = client
    }

    mutating func noteUserMessage(_ text: String, at date: Date) {
        note(date)
        userMessageCount += 1
        // The first message says what the person came for; a couple of later
        // ones say where it went. The middle is left out.
        let redacted = String(sanitizeConversationText(text).prefix(Self.maximumUserMessageCharacters))
        guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if userMessages.count < Self.maximumUserMessages {
            userMessages.append(redacted)
        } else {
            userMessages[Self.maximumUserMessages - 1] = redacted
        }
    }

    mutating func noteTool(_ name: String, at date: Date) {
        note(date)
        let trimmed = String(name.prefix(64))
        guard !trimmed.isEmpty, !tools.contains(trimmed), tools.count < Self.maximumTools else { return }
        tools.append(trimmed)
    }

    mutating func noteSkill(_ id: String, at date: Date) {
        note(date)
        skills.insert(String(id.prefix(128)))
    }

    private mutating func note(_ date: Date) {
        startedAt = startedAt.map { min($0, date) } ?? date
        endedAt = endedAt.map { max($0, date) } ?? date
    }

    /// Nil when the conversation had nothing a person said in it.
    /// A conversation with nothing to learn from: the person said only a few
    /// words in total ("ping", "whoami", "hi") and asked for no tool or skill.
    /// Sending it would spend the budget on noise and tempt the reader to
    /// count it.
    var isTrivial: Bool {
        userMessages.reduce(0) { $0 + $1.count } < 24 && tools.isEmpty && skills.isEmpty
    }

    var digest: ConversationDigest? {
        guard !userMessages.isEmpty, !isTrivial, let startedAt, let endedAt else { return nil }
        return ConversationDigest(
            conversationID: conversationID, client: client, startedAt: startedAt, endedAt: endedAt,
            title: title.map { String(sanitizeConversationText($0).prefix(160)) },
            workingDirectory: workingDirectory.map(Self.projectName),
            userMessages: userMessages, userMessageCount: userMessageCount,
            toolsUsed: tools, skillsUsed: skills.sorted())
    }

    /// The last path component only: what the project was called, not where
    /// on the disk it lives.
    static func projectName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return String((trimmed.split(separator: "/").last.map(String.init) ?? trimmed).prefix(80))
    }
}

struct SkillNameLookup {
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
