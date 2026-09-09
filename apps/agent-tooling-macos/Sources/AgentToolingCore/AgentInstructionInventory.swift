import Foundation

/// What each client reads as standing instructions, and which agent definitions
/// it has, on this Mac and in one project.
///
/// The locations are recorded facts, not guesses, and the pages they were read
/// from are named beside each list. Nothing here is inferred from another
/// client: Claude Code and Codex disagree about which filename they read, and
/// that disagreement is one of the more useful things this can tell somebody.
///
/// Read-only throughout. It reports what exists, how big it is, and that these
/// files are used **together** rather than overriding each other. It does not
/// read what any of them say — instruction files are prose written for an
/// agent, and summarising one would be inventing a claim about behavior.
public enum AgentInstructionInventory {
    /// Where each fact here came from, so a stale one can be rechecked against
    /// the page it was taken from rather than argued about.
    public enum Source {
        public static let claudeInstructions = "https://code.claude.com/docs/en/memory"
        public static let claudeAgents = "https://code.claude.com/docs/en/sub-agents"
        public static let codexInstructions = "https://developers.openai.com/codex/guides/agents-md"
    }

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case instructions
        /// A file scoped to some of the project, loaded when it matches.
        case rule
        case agent
    }

    public enum Scope: String, Hashable, Sendable, CaseIterable {
        case managedPolicy, user, project, localProject
    }

    public struct Entry: Hashable, Sendable {
        public let surface: TargetSurface
        public let kind: Kind
        public let scope: Scope
        public let path: String
        public let byteCount: Int
        /// True when the file is where a client looks but holds nothing. Present
        /// and empty is a different fact from absent, and both are worth seeing.
        public var isEmpty: Bool { byteCount == 0 }
    }

    /// Something worth saying about what was found, in the person's terms.
    public struct Note: Hashable, Sendable {
        public let surface: TargetSurface
        public let detail: String
    }

    public struct Result: Sendable {
        public let entries: [Entry]
        public let notes: [Note]

        public func entries(for surface: TargetSurface, kind: Kind) -> [Entry] {
            entries.filter { $0.surface == surface && $0.kind == kind }
        }
    }

    /// The largest file this reads. Anything bigger is reported at the cap
    /// rather than pulled into memory: the size is all this needs.
    public static let maximumReportedBytes = 4 << 20

    public static func scan(
        homeRoot: URL,
        projectRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> Result {
        var entries: [Entry] = []
        var notes: [Note] = []

        func add(_ surface: TargetSurface, _ kind: Kind, _ scope: Scope, _ url: URL) {
            guard let size = regularFileSize(url, fileManager) else { return }
            entries.append(.init(surface: surface, kind: kind, scope: scope,
                                 path: url.standardizedFileURL.path, byteCount: size))
        }
        func addDirectory(_ surface: TargetSurface, _ kind: Kind, _ scope: Scope, _ directory: URL) {
            for url in markdownFiles(in: directory, fileManager) {
                add(surface, kind, scope, url)
            }
        }

        // Claude Code. Every one of these is loaded and concatenated; none of
        // them replaces another.
        add(.claudeCode, .instructions, .managedPolicy,
            URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/CLAUDE.md"))
        add(.claudeCode, .instructions, .user, homeRoot.appending(path: ".claude/CLAUDE.md"))
        addDirectory(.claudeCode, .rule, .user, homeRoot.appending(path: ".claude/rules"))
        addDirectory(.claudeCode, .agent, .user, homeRoot.appending(path: ".claude/agents"))
        if let projectRoot {
            add(.claudeCode, .instructions, .project, projectRoot.appending(path: "CLAUDE.md"))
            add(.claudeCode, .instructions, .project, projectRoot.appending(path: ".claude/CLAUDE.md"))
            add(.claudeCode, .instructions, .localProject, projectRoot.appending(path: "CLAUDE.local.md"))
            addDirectory(.claudeCode, .rule, .project, projectRoot.appending(path: ".claude/rules"))
            addDirectory(.claudeCode, .agent, .project, projectRoot.appending(path: ".claude/agents"))

            // Claude Code reads CLAUDE.md, not AGENTS.md. A project that has
            // only the latter gives it nothing, and nothing else on this screen
            // would show that.
            let hasClaude = entries.contains {
                $0.surface == .claudeCode && $0.kind == .instructions && $0.scope != .user
                    && $0.scope != .managedPolicy
            }
            if !hasClaude, regularFileSize(projectRoot.appending(path: "AGENTS.md"), fileManager) != nil {
                notes.append(.init(surface: .claudeCode,
                    detail: "This project has an AGENTS.md but no CLAUDE.md. Claude Code reads CLAUDE.md and will not read AGENTS.md, so none of it reaches Claude Code."))
            }
        }

        // Codex. In its own home it uses the first of these that is not empty;
        // from the project root down, every directory contributes.
        for name in ["AGENTS.override.md", "AGENTS.md"] {
            let url = homeRoot.appending(path: ".codex").appending(path: name)
            guard let size = regularFileSize(url, fileManager), size > 0 else { continue }
            entries.append(.init(surface: .codexCLI, kind: .instructions, scope: .user,
                                 path: url.standardizedFileURL.path, byteCount: size))
            break
        }
        if let projectRoot {
            for name in ["AGENTS.override.md", "AGENTS.md", "TEAM_GUIDE.md", ".agents.md"] {
                let url = projectRoot.appending(path: name)
                guard let size = regularFileSize(url, fileManager), size > 0 else { continue }
                entries.append(.init(surface: .codexCLI, kind: .instructions, scope: .project,
                                     path: url.standardizedFileURL.path, byteCount: size))
                break
            }
        }

        return .init(entries: entries.sorted(by: order), notes: notes)
    }

    /// Only a regular file, and only after following any link. A directory or a
    /// dangling link where a client expects a file is not an instruction file.
    private static func regularFileSize(_ url: URL, _ fileManager: FileManager) -> Int? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return min(values.fileSize ?? 0, maximumReportedBytes)
    }

    private static func markdownFiles(in directory: URL, _ fileManager: FileManager) -> [URL] {
        // Recursive, because both clients allow organising these into
        // subfolders, and a rule in one still loads.
        guard let walker = fileManager.enumerator(
            at: directory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            found.append(url)
            if found.count >= 512 { break }
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func order(_ lhs: Entry, _ rhs: Entry) -> Bool {
        [lhs.surface.rawValue, lhs.kind.rawValue, lhs.scope.rawValue, lhs.path]
            .lexicographicallyPrecedes(
                [rhs.surface.rawValue, rhs.kind.rawValue, rhs.scope.rawValue, rhs.path])
    }
}
