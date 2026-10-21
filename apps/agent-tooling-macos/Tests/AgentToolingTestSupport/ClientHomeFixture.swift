import AgentToolingCore
import Foundation

/// Synthetic client homes for first-run and join tests. Planted executable
/// scripts and scripted runners return the same replies without using host tools.
public struct ClientHomeFixture: Sendable {
    /// Which Mac.
    public enum World: String, CaseIterable, Sendable {
        /// Codex 0.164.0, Claude Code 2.1.304 and Gemini CLI 0.38.2; no Kiro
        /// CLI. Three loose skills, three plugins, two connections set up by
        /// hand, and four folders in Claude Code's project history.
        case juniper
        /// Codex and Claude Code, and one loose skill of its own.
        case cedar
        /// No app and nothing any app left behind.
        case emptyMac
    }

    public let world: World
    public let home: FixtureHome
    /// Where each app's tool was planted. Its keys are the apps found here.
    public let tools: [ClientKind: URL]

    /// Saturday, October 17, 2026, 9:41 AM in this Mac's time zone: the
    /// sample world's clock.
    public static let now = sampleDate(month: 10, day: 17, hour: 9, minute: 41)

    /// Plants `world` in a new temporary home. If planting fails partway,
    /// the home is removed before the error is thrown.
    public init(_ world: World) throws {
        let home = try FixtureHome("sample-\(world.rawValue)")
        do {
            var tools: [ClientKind: URL] = [:]
            for client in Self.found(in: world) {
                tools[client] = try home.installTool(
                    client, in: Self.toolFolder(for: client),
                    script: Self.script(answering: Self.answers(for: client, world: world, home: home.url)))
            }
            self.world = world
            self.home = home
            self.tools = tools
            switch world {
            case .juniper: try plantJuniper()
            case .cedar: try plantCedar()
            case .emptyMac: break
            }
        } catch {
            home.remove()
            throw error
        }
    }

    /// The home folder.
    public var url: URL { home.url }

    /// The apps whose tool is here, which setup manages unless told otherwise.
    public var found: Set<ClientKind> { Set(tools.keys) }

    /// What `client`'s tool prints for each command it answers. The planted
    /// script and `scriptedRunner()` both answer from this.
    public func answers(for client: ClientKind) -> [[String]: String] {
        Self.answers(for: client, world: world, home: url)
    }

    /// The first line `client --version` prints here, or nil when the app is
    /// not here.
    public func versionLine(for client: ClientKind) -> String? {
        answers(for: client)[["--version"]]?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// Every app's answers keyed by its tool's name, for a test that adds its
    /// own replies before building a runner.
    public var replies: [String: [[String]: ScriptedCommandRunner.Reply]] {
        var replies: [String: [[String]: ScriptedCommandRunner.Reply]] = [:]
        for client in ClientKind.allCases where tools[client] != nil {
            replies[ClientExecutableLocator.executableName(for: client)] = answers(for: client).mapValues { .standardOutput($0) }
        }
        return replies
    }

    /// A runner that answers as the planted tools do, without starting them.
    /// An app that is not here answers every command as a missing tool does.
    public func scriptedRunner() -> ScriptedCommandRunner {
        ScriptedCommandRunner(
            byTool: replies,
            missingTools: Set(ClientKind.allCases.filter { tools[$0] == nil }.map(ClientExecutableLocator.executableName(for:))))
    }

    /// Where the locator would find `client`'s tool if this home were the
    /// whole Mac.
    public func locate(_ client: ClientKind) -> URL? { home.locate(client) }

    /// The bundled adapters, finding tools only inside this home.
    public var registry: ClientAdapterRegistry {
        let home = home
        return ClientAdapterRegistry.bundled(locate: { client, _ in home.locate(client) })
    }

    /// The four folder names in `~/.claude/projects` on Juniper, named as
    /// Claude Code names them after the folder it ran in. Empty elsewhere.
    public var projectHistoryEntryNames: [String] {
        guard world == .juniper else { return [] }
        return Self.projectFolders.map { Self.historyEntryName(for: home.appending($0)) }.sorted()
    }

    /// Plants an unchosen client skill, saved conversation and document to
    /// verify that the first read stays within its declared scope.
    @discardableResult
    public func plantDecoys() throws -> [URL] {
        let planted: [(String, String)] = [
            (".kiro/skills/kiro-notes/SKILL.md", "---\nname: kiro-notes\ndescription: A decoy no first read opens.\n---\n"),
            (
                ".codex/sessions/2026/10/16/rollout-2026-10-16T18-02-11-decoy.jsonl",
                #"{"type":"message","role":"user","content":"A decoy conversation no first read opens."}"# + "\n"
            ),
            ("Documents/sketchbook/notes.md", "A decoy in Documents that no first read opens.\n"),
        ]
        for (relative, text) in planted { try home.plant(relative, text) }
        return planted.map { home.appending($0.0) }
    }

    public func remove() { home.remove() }

    // MARK: - Juniper

    private static let projectFolders = ["code/storefront", "code/docs-site", "code/cli-tools", "Documents/sketchbook"]

    private func plantJuniper() throws {
        // Frontend Design: two different copies. Claude Code's has three files
        // and changed on October 2; Codex's has two and changed on August 14,
        // and Gemini CLI reads the same folder through ~/.agents/skills.
        try home.plantSkill(
            ".claude/skills/frontend-design", name: "frontend-design",
            description: "Builds distinctive UI with a clear visual direction.",
            instructions: "Choose one visual direction, then build every screen from it.",
            files: [
                "reference/typography.md": "Pair one display face with one text face.\n",
                "reference/color.md": "Start from two neutrals and one accent.\n",
            ],
            modifiedAt: Self.sampleDate(month: 10, day: 2, hour: 16, minute: 20))
        try home.plantSkill(
            ".agents/skills/frontend-design", name: "frontend-design",
            description: "Builds distinctive UI with a clear visual direction.",
            instructions: "Pick a direction and keep to it.",
            files: ["reference/typography.md": "Use one face for headings.\n"],
            modifiedAt: Self.sampleDate(month: 8, day: 14, hour: 11, minute: 5))
        // Webapp Testing: the same content in Claude Code and in Codex.
        for folder in [".claude/skills/webapp-testing", ".codex/skills/webapp-testing"] {
            try home.plantSkill(
                folder, name: "webapp-testing", description: "Drives a local web app with Playwright to check a change.",
                instructions: "Start the app, open it with Playwright, and check the change.",
                files: ["scripts/check.sh": "#!/bin/sh\nnpx playwright test\n"],
                modifiedAt: Self.sampleDate(month: 9, day: 21, hour: 10, minute: 0))
        }
        // Release Notes: only in Claude Code, written by the person.
        try home.plantSkill(
            ".claude/skills/release-notes", name: "release-notes", description: "Drafts release notes from merged pull requests.",
            instructions: "Read the merged pull requests since the last tag, then group them by area.",
            modifiedAt: Self.sampleDate(month: 10, day: 9, hour: 14, minute: 30))

        // Plugins: GitHub and Sentry in Claude Code, Linear in Codex. The
        // apps report them through `plugin list --json`; their folders are
        // where those listings point.
        for plugin in ["github", "sentry"] {
            try home.plant(
                ".claude/plugins/cache/claude-plugins-official/\(plugin)/1.0.0/.claude-plugin/plugin.json",
                #"{"name":"\#(plugin)","version":"1.0.0"}"# + "\n")
        }
        try home.plantSkill(
            ".claude/plugins/cache/claude-plugins-official/sentry/1.0.0/skills/triage-issue", name: "triage-issue",
            description: "Triages a Sentry issue from its events and traces.",
            instructions: "Read the issue's latest events, then name the likely cause.")
        try home.plant(
            ".codex/plugins/cache/openai-curated/linear/1.2.0/.codex-plugin/plugin.json",
            #"{"name":"linear","version":"1.2.0","description":"Linear issues and projects inside Codex."}"# + "\n")
        try home.plant(
            ".claude/settings.json",
            #"{"enabledPlugins":{"github@claude-plugins-official":true,"sentry@claude-plugins-official":true}}"# + "\n")

        // Connections set up by hand: Context7 in Claude Code and Gemini CLI,
        // Playwright in Claude Code and Codex.
        try home.plant(
            ".claude.json",
            #"""
            {"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp"},"playwright":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]}}}

            """#)
        try home.plant(".gemini/settings.json", #"{"mcpServers":{"context7":{"httpUrl":"https://mcp.context7.com/mcp"}}}"# + "\n")
        try home.plant(".codex/config.toml", "[mcp_servers.playwright]\ncommand = \"npx\"\nargs = [\"@playwright/mcp@latest\"]\n")

        // Claude Code's project history: four folders, each named after a
        // folder Claude Code ran in, holding a conversation no first read
        // opens. Three of the project folders are here; the fourth, in
        // ~/Documents, is planted only with the decoys.
        for folder in Self.projectFolders {
            let entry = Self.historyEntryName(for: home.appending(folder))
            try home.plant(
                ".claude/projects/\(entry)/0b6e7c1a-5d1f-4c55-9a52-sample.jsonl",
                #"{"type":"user","message":"A conversation no first read opens."}"# + "\n")
        }
        try home.plant("code/storefront/CLAUDE.md", "# Storefront\n")
        try home.plant("code/storefront/.mcp.json", #"{"mcpServers":{}}"# + "\n")
        try home.plant("code/docs-site/AGENTS.md", "# Docs site\n")
        try home.plant("code/cli-tools/README.md", "# CLI tools\n")
    }

    // MARK: - Cedar

    private func plantCedar() throws {
        try home.plantSkill(
            ".claude/skills/db-migrations", name: "db-migrations", description: "Writes and checks database migrations.",
            instructions: "Write the migration, then run it against a copy first.",
            modifiedAt: Self.sampleDate(month: 9, day: 30, hour: 15, minute: 45))
    }

    // MARK: - The tools

    private static func found(in world: World) -> [ClientKind] {
        switch world {
        case .juniper: [.codex, .claude, .gemini]
        case .cedar: [.codex, .claude]
        case .emptyMac: []
        }
    }

    private static func toolFolder(for client: ClientKind) -> String {
        switch client {
        case .claude: ".local/bin"
        case .codex, .gemini, .kiro: ".npm-global/bin"
        }
    }

    private static func answers(for client: ClientKind, world: World, home: URL) -> [[String]: String] {
        guard found(in: world).contains(client) else { return [:] }
        let homePath = ProjectPath.canonical(home)
        switch client {
        case .codex:
            let installed =
                world == .juniper
                ? #"[{"pluginId":"linear@openai-curated","name":"linear","source":{"path":"\#(homePath)/.codex/plugins/cache/openai-curated/linear/1.2.0"},"enabled":true,"version":"1.2.0"}]"#
                : "[]"
            let servers =
                world == .juniper
                ? #"[{"name":"playwright","enabled":true,"transport":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]},"auth_status":"unsupported"}]"#
                : "[]"
            return [
                ["--version"]: "codex-cli 0.164.0\n",
                ["plugin", "list", "--json"]: #"{"installed":\#(installed),"available":[]}"# + "\n",
                ["mcp", "list", "--json"]: servers + "\n",
            ]
        case .claude:
            let listed =
                world == .juniper
                ? #"""
                [{"id":"github@claude-plugins-official","version":"1.0.0","scope":"user","enabled":true,"installPath":"\#(homePath)/.claude/plugins/cache/claude-plugins-official/github/1.0.0","mcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/"}}},{"id":"sentry@claude-plugins-official","version":"1.0.0","scope":"user","enabled":true,"installPath":"\#(homePath)/.claude/plugins/cache/claude-plugins-official/sentry/1.0.0","mcpServers":{"sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"}}}]
                """#
                : "[]"
            return [
                ["--version"]: "2.1.304 (Claude Code)\n",
                ["plugin", "list", "--json"]: listed + "\n",
                ["auth", "status", "--json"]:
                    #"{"loggedIn":true,"authMethod":"claude.ai","email":"you@example.com","subscriptionType":"max"}"# + "\n",
            ]
        case .gemini:
            return [["--version"]: "0.38.2\n"]
        case .kiro:
            return [:]
        }
    }

    /// A POSIX shell script that prints each scripted answer for its exact
    /// arguments and refuses anything else.
    private static func script(answering answers: [[String]: String]) -> String {
        var lines = ["#!/bin/sh", "# A sample-world stand-in that answers what a first read runs.", "case \"$*\" in"]
        for (arguments, output) in answers.sorted(by: { $0.key.joined(separator: " ") < $1.key.joined(separator: " ") }) {
            lines.append("'\(arguments.joined(separator: " "))')")
            lines.append("cat <<'AGENT_TOOLING_SAMPLE_WORLD'")
            lines.append(output.hasSuffix("\n") ? String(output.dropLast()) : output)
            lines.append("AGENT_TOOLING_SAMPLE_WORLD")
            lines.append(";;")
        }
        lines.append("*)")
        lines.append("echo \"not scripted: $*\" >&2")
        lines.append("exit 1")
        lines.append(";;")
        lines.append("esac")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// Claude Code's name for the history folder of a folder it ran in: the
    /// absolute path with every `/` and `.` replaced by `-`.
    private static func historyEntryName(for folder: URL) -> String {
        ProjectPath.canonical(folder).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    private static func sampleDate(month: Int, day: Int, hour: Int, minute: Int) -> Date {
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: month, day: day, hour: hour,
            minute: minute)
        return components.date ?? Date(timeIntervalSince1970: 0)
    }
}
