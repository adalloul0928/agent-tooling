import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Paste to import")
struct PastedDefinitionParserTests {
    private func mcpImport(_ text: String) throws -> PastedMCPImport {
        guard case .mcp(let result) = try PastedDefinitionParser.parse(text) else {
            Issue.record("Expected an MCP import for: \(text)")
            throw PasteImportError.empty
        }
        return result
    }

    private func skillImport(_ text: String) throws -> PastedSkillImport {
        guard case .skill(let result) = try PastedDefinitionParser.parse(text) else {
            Issue.record("Expected a skill import")
            throw PasteImportError.empty
        }
        return result
    }

    @Test("Reads an HTTP claude mcp add command and preselects only Claude Code")
    func readsClaudeHTTPCommand() throws {
        let result = try mcpImport("claude mcp add --transport http --scope user sentry https://mcp.sentry.dev/mcp")

        #expect(result.shape == .claudeCommand)
        let server = try #require(result.servers.first)
        #expect(server.draft.name == "sentry")
        #expect(server.draft.endpoint == "https://mcp.sentry.dev/mcp")
        #expect(server.draft.transport == .http)
        #expect(server.draft.scope == .user)
        #expect(server.draft.selectedTargets == [.claude])
        #expect(server.draft.authentication == "OAuth")
    }

    @Test("Reads a stdio command after the argument separator and reports the adjusted name")
    func readsStdioCommand() throws {
        let result = try mcpImport("$ claude mcp add --transport stdio My_Server -- npx -y @modelcontextprotocol/server-github")

        let server = try #require(result.servers.first)
        #expect(server.draft.name == "my-server")
        #expect(server.draft.transport == .stdio)
        #expect(server.draft.endpoint == "npx -y @modelcontextprotocol/server-github")
        #expect(server.notes.contains { $0.contains("my-server") })
    }

    @Test("Keeps the server command intact when it was pasted without the separator")
    func readsCommandTailWithoutSeparator() throws {
        let result = try mcpImport("claude mcp add weather npx -y weather-mcp")

        let server = try #require(result.servers.first)
        #expect(server.draft.transport == .stdio)
        #expect(server.draft.endpoint == "npx -y weather-mcp")
    }

    @Test("Reads an add-json command as the client's own JSON shape")
    func readsAddJSONCommand() throws {
        let result = try mcpImport(
            "claude mcp add-json weather '{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"weather-mcp\"]}'"
        )

        let server = try #require(result.servers.first)
        #expect(result.shape == .claudeCommand)
        #expect(server.draft.name == "weather")
        #expect(server.draft.transport == .stdio)
        #expect(server.draft.endpoint == "npx -y weather-mcp")
        #expect(server.draft.selectedTargets == [.claude])

        #expect(throws: PasteImportError.missingDestination) {
            _ = try PastedDefinitionParser.parse("claude mcp add-json weather")
        }
    }

    @Test("Reads the Codex url flag and the Gemini project scope")
    func readsCodexAndGeminiShapes() throws {
        let codex = try mcpImport("codex mcp add ticktick --url https://ticktick.example.com/mcp")
        let codexServer = try #require(codex.servers.first)
        #expect(codex.shape == .codexCommand)
        #expect(codexServer.draft.selectedTargets == [.codex])
        #expect(codexServer.draft.transport == .http)
        #expect(codexServer.draft.endpoint == "https://ticktick.example.com/mcp")

        let gemini = try mcpImport("gemini mcp add --scope project files -- npx -y @scope/files")
        let geminiServer = try #require(gemini.servers.first)
        #expect(gemini.shape == .geminiCommand)
        #expect(geminiServer.draft.selectedTargets == [.gemini])
        #expect(geminiServer.draft.scope == .project)
        #expect(geminiServer.notes.contains { $0.contains("project folder") })
    }

    @Test("Keeps credential names and never their values")
    func dropsCredentialValues() throws {
        let result = try mcpImport("claude mcp add gh -e GITHUB_TOKEN=not-a-real-token-value -- npx -y server-github")

        let server = try #require(result.servers.first)
        #expect(server.draft.authentication == "API key")
        #expect(server.notes.contains { $0.contains("GITHUB_TOKEN") })
        #expect(!server.notes.contains { $0.contains("not-a-real-token-value") })
        #expect(!server.draft.endpoint.contains("not-a-real-token-value"))
    }

    @Test("Reads a client mcpServers JSON block")
    func readsJSONBlock() throws {
        let result = try mcpImport(
            """
            {
              "mcpServers": {
                "github": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-github"],
                  "env": { "GITHUB_TOKEN": "not-a-real-token-value" },
                  "disabled": false
                }
              }
            }
            """
        )

        #expect(result.shape == .json)
        let server = try #require(result.servers.first)
        #expect(server.draft.name == "github")
        #expect(server.draft.transport == .stdio)
        #expect(server.draft.endpoint == "npx -y @modelcontextprotocol/server-github")
        #expect(server.notes.contains { $0.contains("GITHUB_TOKEN") })
        #expect(!server.notes.contains { $0.contains("not-a-real-token-value") })
        #expect(server.notes.contains { $0.contains("Ignored fields: disabled") })
    }

    @Test("Reads several servers from one JSON block, in name order")
    func readsSeveralServersFromJSON() throws {
        let result = try mcpImport(
            """
            {"mcpServers": {
              "linear": {"type": "http", "url": "https://mcp.linear.app/mcp"},
              "context7": {"command": "npx", "args": ["-y", "context7"]}
            }}
            """
        )

        #expect(result.servers.map(\.draft.name) == ["context7", "linear"])
    }

    @Test("Reads a bare server object and a bare URL by suggesting a name")
    func readsBareShapes() throws {
        let bareObject = try mcpImport("{\"type\": \"http\", \"url\": \"https://mcp.linear.app/mcp\"}")
        let objectServer = try #require(bareObject.servers.first)
        #expect(objectServer.draft.name == "linear")
        #expect(objectServer.draft.transport == .http)

        let bareURL = try mcpImport("https://mcp.notion.com/mcp")
        let urlServer = try #require(bareURL.servers.first)
        #expect(bareURL.shape == .url)
        #expect(urlServer.draft.name == "notion")
        #expect(urlServer.draft.transport == .http)
    }

    @Test("Reads a SKILL.md into a skill draft and names what is still missing")
    func readsSkillMarkdown() throws {
        let result = try skillImport(
            """
            ---
            name: release-notes
            description: "Writes release notes from merged pull requests."
            license: MIT
            ---

            # Release Notes

            ## When to use this skill

            - The user asks for release notes
            - A milestone has just closed

            ## When not to use this skill

            Do not use it for marketing copy.
            """
        )

        #expect(result.draft.name == "release-notes")
        #expect(result.draft.purpose == "Writes release notes from merged pull requests.")
        #expect(result.draft.triggers.prefix(2) == ["The user asks for release notes", "A milestone has just closed"])
        #expect(result.draft.negativeTrigger == "Do not use it for marketing copy.")
        #expect(result.missingFields.isEmpty)
        #expect(result.notes.contains { $0.contains("license") })
    }

    @Test("Reports the fields a bare SKILL.md frontmatter could not supply")
    func reportsMissingSkillFields() throws {
        let result = try skillImport(
            """
            ---
            name: triage
            description: Sorts incoming issues.
            ---
            """
        )

        #expect(result.draft.name == "triage")
        #expect(result.missingFields == ["At least one trigger", "A negative trigger"])
    }

    @Test("Refuses input that is too long, has control characters, or is empty")
    func refusesUnsafeInput() {
        #expect(throws: PasteImportError.tooLong(PastedDefinitionParser.maximumInputLength)) {
            _ = try PastedDefinitionParser.parse(String(repeating: "a", count: PastedDefinitionParser.maximumInputLength + 1))
        }
        #expect(throws: PasteImportError.unsupportedCharacters) {
            _ = try PastedDefinitionParser.parse("claude mcp add name \u{0007} https://example.com/mcp")
        }
        #expect(throws: PasteImportError.empty) {
            _ = try PastedDefinitionParser.parse("   \n  ")
        }
    }

    @Test("Says what it could not read in a malformed command")
    func reportsMalformedCommands() {
        #expect(throws: PasteImportError.unsupportedExecutable("please")) {
            _ = try PastedDefinitionParser.parse("please add my server")
        }
        #expect(throws: PasteImportError.notAnAddCommand("claude plugin install")) {
            _ = try PastedDefinitionParser.parse("claude plugin install pack@market")
        }
        #expect(throws: PasteImportError.missingServerName) {
            _ = try PastedDefinitionParser.parse("claude mcp add")
        }
        #expect(throws: PasteImportError.missingDestination) {
            _ = try PastedDefinitionParser.parse("claude mcp add lonely")
        }
        #expect(throws: PasteImportError.unknownFlag("--dangerously-skip")) {
            _ = try PastedDefinitionParser.parse("claude mcp add x --dangerously-skip -- npx server")
        }
        #expect(throws: PasteImportError.multipleCommands(2)) {
            _ = try PastedDefinitionParser.parse("claude mcp add a -- npx a\nclaude mcp add b -- npx b")
        }
    }

    @Test("Refuses a destination that carries a credential")
    func refusesCredentialBearingDestinations() throws {
        #expect(throws: PasteImportError.self) {
            _ = try PastedDefinitionParser.parse("claude mcp add tokenized https://example.com/mcp?api_key=abc123")
        }
        #expect(throws: PasteImportError.self) {
            _ = try PastedDefinitionParser.parse("claude mcp add leaky -- npx server --api-key abc123")
        }
    }

    @Test("Says what it could not read in malformed JSON and SKILL.md")
    func reportsMalformedDocuments() {
        #expect(throws: PasteImportError.self) {
            _ = try PastedDefinitionParser.parse("{\"mcpServers\": {")
        }
        #expect(throws: PasteImportError.noServersInJSON) {
            _ = try PastedDefinitionParser.parse("{\"other\": 12}")
        }
        #expect(throws: PasteImportError.invalidSkill("The frontmatter has no closing --- line.")) {
            _ = try PastedDefinitionParser.parse("---\nname: broken\n")
        }
        #expect(throws: PasteImportError.invalidSkill("The frontmatter has no description field.")) {
            _ = try PastedDefinitionParser.parse("---\nname: broken\n---\n")
        }
    }
}
