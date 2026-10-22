import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The sample world on disk reads the way the mockups say it does, whether
/// its tools are scripted or actually run, so every later suite can build its
/// fixtures from it and trust what they show.
@Suite("Sample world homes", .timeLimit(.minutes(5)))
struct ClientHomeFixtureTests {
    @Test func juniperIsFoundWithItsThreeApps() throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        #expect(world.found == [.codex, .claude, .gemini])
        #expect(world.locate(.codex) == world.home.appending(".npm-global/bin/codex").standardizedFileURL)
        #expect(world.locate(.claude) == world.home.appending(".local/bin/claude").standardizedFileURL)
        #expect(world.locate(.gemini) == world.home.appending(".npm-global/bin/gemini").standardizedFileURL)
        #expect(world.locate(.kiro) == nil)
        #expect(world.versionLine(for: .codex) == "codex-cli 0.164.0")
        #expect(world.versionLine(for: .claude) == "2.1.304 (Claude Code)")
        #expect(world.versionLine(for: .gemini) == "0.38.2")
        #expect(world.versionLine(for: .kiro) == nil)
    }

    @Test func juniperReadsAsTheSampleWorldDescribesIt() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let read = await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)
        let bySurface = Dictionary(uniqueKeysWithValues: read.map { ($0.surface, $0) })
        let codex = try #require(bySurface[.codexCLI])
        let claude = try #require(bySurface[.claudeCode])
        let gemini = try #require(bySurface[.geminiCLI])

        #expect(codex.version == "codex-cli 0.164.0")
        #expect(claude.version == "2.1.304 (Claude Code)")
        #expect(gemini.version == "0.38.2")
        #expect(Set(codex.discoveredSkills) == ["frontend-design", "webapp-testing"])
        #expect(Set(claude.discoveredSkills) == ["frontend-design", "webapp-testing", "release-notes", "sentry:triage-issue"])
        #expect(gemini.discoveredSkills == ["frontend-design"])
        #expect(codex.discoveredPlugins == ["linear@openai-curated"])
        #expect(Set(claude.discoveredPlugins) == ["github@claude-plugins-official", "sentry@claude-plugins-official"])
        #expect(gemini.discoveredPlugins.isEmpty)
        #expect(codex.discoveredMCPServers == ["playwright"])
        #expect(Set(claude.discoveredMCPServers) == ["context7", "playwright", "github", "sentry"])
        #expect(gemini.discoveredMCPServers == ["context7"])
        // Gemini CLI's one skill is Codex's copy, read through ~/.agents/skills.
        #expect(gemini.skillMetadata["frontend-design"]?.path == codex.skillMetadata["frontend-design"]?.path)
    }

    /// The planted tools are real scripts: run, they answer what the scripted
    /// runner answers, so a read through the real runner sees the same Mac.
    @Test func theToolsAnswerWhenRunForReal() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let runner = ProcessCommandRunner(timeout: .seconds(20), homeURL: world.url)

        let real = await world.registry.scanAll(homeURL: world.url, runner: runner, clients: world.found)
        let scripted = await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)

        #expect(real.map(\.version) == scripted.map(\.version))
        #expect(real.map(\.discoveredSkills) == scripted.map(\.discoveredSkills))
        #expect(real.map(\.discoveredPlugins) == scripted.map(\.discoveredPlugins))
        #expect(real.map(\.discoveredMCPServers) == scripted.map(\.discoveredMCPServers))
        let unscripted = try await runner.run(
            executable: try #require(world.locate(.codex)).path(percentEncoded: false), arguments: ["login"], currentDirectory: nil)
        #expect(unscripted.status == 1)
    }

    /// The library a first run on Juniper makes: eight entries, the plugins'
    /// own skill and connections inside them.
    @Test func aFirstRunOnJuniperMakesTheSampleLibrary() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let support = try TemporaryFolder("sample-juniper-support").url
        defer { try? FileManager.default.removeItem(at: support) }

        let store = try await WorkspaceLocator(root: support).openOrCreate(
            homeURL: world.url, runner: world.scriptedRunner(), registry: world.registry)

        let artifacts = try #require(try store.snapshot()?.document.artifacts)
        let entries = artifacts.filter { $0.identity.parentPackageID == nil }
        #expect(
            Set(entries.map(\.identity.displayName)) == [
                "Frontend Design", "Webapp Testing", "Release Notes", "GitHub", "Sentry", "Linear", "Context7", "Playwright",
            ])
        let inside = artifacts.filter { $0.identity.parentPackageID != nil }
        #expect(Set(inside.map(\.declaredName)) == ["sentry:triage-issue", "github", "sentry"])
    }

    @Test func cedarHasTwoAppsAndOneSkillOfItsOwn() async throws {
        let world = try ClientHomeFixture(.cedar)
        defer { world.remove() }

        let read = await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)

        #expect(world.found == [.codex, .claude])
        #expect(read.compactMap(\.version).sorted() == ["2.1.304 (Claude Code)", "codex-cli 0.164.0"])
        #expect(read.flatMap(\.discoveredSkills) == ["db-migrations"])
        #expect(read.allSatisfy { $0.discoveredPlugins.isEmpty && $0.discoveredMCPServers.isEmpty })
        #expect(world.projectHistoryEntryNames.isEmpty)
    }

    @Test func theEmptyMacHasNothing() async throws {
        let world = try ClientHomeFixture(.emptyMac)
        defer { world.remove() }

        let read = await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner())

        #expect(world.found.isEmpty)
        #expect(read.allSatisfy { !$0.installed && !$0.commandAvailable })
        #expect(await world.scriptedRunner().launches.isEmpty)
    }

    /// Four folders in Claude Code's history, named as Claude Code names
    /// them; three of the projects are on disk, the fourth in ~/Documents
    /// only with the decoys.
    @Test func juniperHasFourFoldersInClaudeCodesHistory() throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }

        let names = world.projectHistoryEntryNames
        #expect(names.count == 4)
        #expect(names.allSatisfy { $0.hasPrefix("-") && !$0.contains("/") && !$0.contains(".") })
        let listed = try FileManager.default.contentsOfDirectory(
            atPath: world.home.appending(".claude/projects").path(percentEncoded: false))
        #expect(Set(listed) == Set(names))
        #expect(ProjectDiscovery.sessionIndexRoots(homeURL: world.url).count == 3)
        try world.plantDecoys()
        #expect(ProjectDiscovery.sessionIndexRoots(homeURL: world.url).count == 4)
    }

    @Test func theDecoysAreWhereNoFirstReadLooks() async throws {
        let world = try ClientHomeFixture(.juniper)
        defer { world.remove() }
        let decoys = try world.plantDecoys()
        #expect(decoys.count == 3)

        let manifest = FirstReadManifest.build(chosen: world.found, homeURL: world.url, includeProjectHistory: true)
        for decoy in decoys {
            for client in world.found {
                #expect(manifest.place(containing: decoy, for: client) == nil, "\(decoy.path(percentEncoded: false))")
            }
        }
        let read = await world.registry.scanAll(homeURL: world.url, runner: world.scriptedRunner(), clients: world.found)
        #expect(!read.flatMap(\.discoveredSkills).contains("kiro-notes"))
        #expect(read.allSatisfy { $0.skillMetadata["release-notes"]?.externalManager == nil })
    }

    /// Uses the same local time in every test environment.
    @Test func theSampleClockIsSaturdayMorning() {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            in: .current, from: ClientHomeFixture.now)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 10, 17, 9, 41])
        #expect(parts.weekday == 7, "a Saturday")
    }

    @Test func aFixtureHomeFindsOnlyItsOwnTools() throws {
        let home = try FixtureHome("fixture-home")
        defer { home.remove() }

        #expect(home.locate(.codex) == nil)
        let codex = try home.installTool(.codex, in: ".bun/bin")
        #expect(home.locate(.codex) == codex)
        #expect(home.owns(codex.deletingLastPathComponent()))
        #expect(!home.owns(URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory)))
        #expect(FileManager.default.isExecutableFile(atPath: codex.path(percentEncoded: false)))
    }

    /// A fixture finds a tool exactly where the locator would if the fixture
    /// were the whole Mac, in every world, for every app, found or not.
    @Test(arguments: ClientHomeFixture.World.allCases)
    func aFixtureFindsEachToolWhereTheLocatorWould(world: ClientHomeFixture.World) throws {
        let fixture = try ClientHomeFixture(world)
        defer { fixture.remove() }

        for client in ClientKind.allCases {
            let located = ClientExecutableLocator.locate(client, homeURL: fixture.url, searching: fixture.home.owns)
            #expect(fixture.locate(client) == located, "\(client)")
            #expect(located == fixture.tools[client], "\(client)")
        }
    }

    @Test func aPlantedSkillIsASkillFolderDatedAsAsked() throws {
        let home = try FixtureHome("fixture-skill")
        defer { home.remove() }
        let date = Date(timeIntervalSince1970: 1_786_000_000)

        try home.plantSkill(
            ".claude/skills/sample", name: "sample", description: "A sample.", files: ["notes/a.md": "a\n"], modifiedAt: date)

        let folder = home.appending(".claude/skills/sample", directoryHint: .isDirectory)
        let text = try String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8)
        #expect(try SkillFrontmatter.parse(text).name == "sample")
        #expect(try SkillFrontmatter.parse(text).description == "A sample.")
        for relative in ["SKILL.md", "notes/a.md"] {
            let values = try folder.appending(path: relative).resourceValues(forKeys: [.contentModificationDateKey])
            #expect(values.contentModificationDate == date, "\(relative)")
        }
    }
}
