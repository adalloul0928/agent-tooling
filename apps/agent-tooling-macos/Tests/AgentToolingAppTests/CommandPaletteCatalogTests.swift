import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// One search over every named object and action the app already holds.
///
/// The catalog is the palette's whole claim about what exists, so what it must
/// never do is offer somewhere a person cannot get to: an app this Mac has
/// stopped managing, or a screen that is no longer in the app.
@Suite("Command palette catalog and sidebar health")
@MainActor
struct CommandPaletteCatalogTests {
    @Test("Unchecked apps disappear from search")
    func excludesUncheckedClients() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        await fixture.workspace.device.setEnabled(.gemini, false)
        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        #expect(!items.contains { $0.outcome == .openClient(.gemini) })
        #expect(items.contains { $0.outcome == .openClient(.claude) })

        await fixture.workspace.device.setEnabled(.gemini, true)
        #expect(
            CommandPaletteCatalog.items(for: fixture.workspace)
                .contains { $0.outcome == .openClient(.gemini) })
    }

    @Test("Indexes every screen, the shell actions, and the named objects")
    func indexesScreensActionsAndObjects() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        for section in AppSection.allCases {
            #expect(items.contains { $0.outcome == .navigate(section) })
        }
        for client in ClientKind.allCases {
            #expect(items.contains { $0.outcome == .openClient(client) })
        }
        #expect(items.contains { $0.outcome == .checkSetup })
        #expect(items.contains { $0.outcome == .reviewSync })
        #expect(items.contains { $0.outcome == .openSkill(Self.identifier(ShellRenderFixture.skill)) })
        #expect(
            items.contains {
                $0.outcome == .screenRequest(.selectPlugin(Self.identifier(ShellRenderFixture.plugin)))
            })
        #expect(
            items.contains {
                $0.outcome == .screenRequest(.selectMCPServer(Self.identifier(ShellRenderFixture.server)))
            })
        #expect(items.contains { $0.title == "Starter" && $0.contextLabel == "Presets" })
        #expect(items.contains { $0.title == "Project A" && $0.contextLabel == "Projects" })
    }

    /// A plugin's own skills reach the library folded into the plugin's row, so
    /// listing them again would offer two results for one thing.
    @Test("A tool that arrives inside a plugin is not listed twice")
    func nestedToolsAreNotListedSeparately() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        #expect(!items.contains { $0.title == "Bundled Skill" })
    }

    @Test("New workspace names remain searchable alongside established route names")
    func workspaceNamesAndLegacyRoutesRemainSearchable() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        let expected: [(AppSection, String)] = [
            (.overview, "Home"), (.skills, "Library"), (.marketplace, "Discover"), (.syncCenter, "Apps"),
        ]
        for (route, title) in expected {
            let item = try #require(items.first { $0.id == "section.\(route.id)" })
            #expect(item.title == title)
            #expect(item.keywords.contains(route.rawValue))
        }
    }

    @Test("Typing a name selects the object; typing an action reaches the action")
    func rankingReachesObjectsAndActions() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        let byName = CommandPaletteMatcher.rank(items, query: "Standalone Skill")
        #expect(byName.first?.outcome == .openSkill(Self.identifier(ShellRenderFixture.skill)))

        let byAction = CommandPaletteMatcher.rank(items, query: "check setup")
        #expect(byAction.first?.outcome == .checkSetup)

        #expect(CommandPaletteMatcher.rank(items, query: "zzzznothing").isEmpty)
    }

    @Test("A screen request names the screen that answers it")
    func screenRequestsCarryTheirScreen() {
        #expect(ScreenRequest.addMCPServer.section == .mcpServers)
        #expect(ScreenRequest.pasteImport.section == .mcpServers)
        #expect(ScreenRequest.selectMCPServer("linear").section == .mcpServers)
        #expect(ScreenRequest.selectPlugin("release-tools").section == .plugins)
        #expect(ScreenRequest.selectReceipt("a-receipt-id").section == .activity)
        #expect(ScreenRequest.selectMCPServer("linear").itemID == "linear")
        #expect(ScreenRequest.selectPlugin("release-tools").itemID == "release-tools")
        #expect(ScreenRequest.selectReceipt("a-receipt-id").itemID == "a-receipt-id")
        #expect(ScreenRequest.addMCPServer.itemID == nil)
        #expect(ScreenRequest.pasteImport.itemID == nil)
    }

    @Test("Open Activity and Open History are both in the catalog")
    func activityAndHistoryAreSearchableSections() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        let activity = try #require(items.first { $0.id == "section.\(AppSection.activity.id)" })
        #expect(activity.title == "Activity")
        #expect(activity.outcome == .navigate(.activity))

        let history = try #require(items.first { $0.id == "section.\(AppSection.history.id)" })
        #expect(history.title == "History")
        #expect(history.outcome == .navigate(.history))
    }

    /// A receipt is searchable by name and opens Activity on exactly the
    /// receipt it names, the same way a plugin or server row opens its screen.
    @Test("A receipt is searchable and names Activity as its screen")
    func receiptsAreSearchableAndNameActivity() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let receipt = try fixture.seedActivity()

        let items = CommandPaletteCatalog.items(for: fixture.workspace)
        let identifier = receipt.id.uuidString.lowercased()
        let item = try #require(items.first { $0.id == "receipt.\(identifier)" })

        #expect(item.title == receipt.title)
        #expect(item.contextLabel == "Activity")
        #expect(item.outcome == .screenRequest(.selectReceipt(identifier)))

        let byName = CommandPaletteMatcher.rank(items, query: receipt.title)
        #expect(byName.contains { $0.id == item.id })
    }

    /// A workspace that never recorded a receipt offers none — the palette
    /// never invents one, the same way it never invents a tag or a connector.
    @Test("No receipts, no receipt results")
    func noReceiptsMeansNoReceiptResults() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let items = CommandPaletteCatalog.items(for: fixture.workspace)

        #expect(!items.contains { $0.id.hasPrefix("receipt.") })
    }

    /// A screen with nothing to report carries no sidebar glyph. The sidebar
    /// only ever draws one for `.attention`, and nothing in a workspace whose
    /// items are merely requested has earned that.
    @Test("A screen with nothing to report has no sidebar dot")
    func sidebarStaysQuietWhenThereIsNothingToReport() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let library = try #require(fixture.workspace.library.state?.library)

        let health = SectionHealth(inventory: VersionedInventoryProjection.inventory(library))

        #expect(health[.skills] == nil)
        #expect(health[.plugins] == nil)
        #expect(health[.projects] == nil)
        for group in NavigationGroup.allCases {
            for section in group.sections {
                #expect(health[section] != .attention)
            }
        }
    }

    private static func identifier(_ id: ArtifactID) -> String {
        id.rawValue.uuidString.lowercased()
    }
}
