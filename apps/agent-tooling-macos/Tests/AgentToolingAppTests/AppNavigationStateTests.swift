import AgentToolingCore
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("External navigation request queue")
struct AppNavigationStateTests {
    @Test("Client navigation keeps an exact scope until All Clients is chosen")
    @MainActor
    func clientScopeIsDurableAndExplicitlyCleared() {
        let navigation = AppNavigationState()

        navigation.openClient(.codex)

        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.selectedClient == .codex)
        navigation.consumeRequestedSection(.overview)
        #expect(navigation.requestedSection == .syncCenter)
        navigation.consumeRequestedSection(.syncCenter)
        #expect(navigation.requestedSection == nil)
        #expect(navigation.selectedClient == .codex)

        navigation.showAllClients()

        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.selectedClient == nil)
    }

    /// A palette action with no row of its own — "Add MCP server" or "Paste to
    /// import" — has to land somewhere a screen can answer it, the same way a
    /// row-scoped one lands as `requestedItemID`.
    @Test("A screen request with no row lands on its section and waits to be answered")
    @MainActor
    func screenRequestLandsOnItsSectionAndWaitsToBeAnswered() {
        let navigation = AppNavigationState()

        navigation.openScreenRequest(.pasteImport)

        #expect(navigation.requestedSection == .mcpServers)
        #expect(navigation.requestedScreenRequest == .pasteImport)

        // Consuming a different request than the one waiting changes nothing:
        // the screen that has not answered yet still gets its turn.
        navigation.consumeScreenRequest(.addMCPServer)
        #expect(navigation.requestedScreenRequest == .pasteImport)

        navigation.consumeScreenRequest(.pasteImport)
        #expect(navigation.requestedScreenRequest == nil)
    }

    /// Every other route is one-shot and exclusive: landing somewhere new must
    /// not leave a stale screen request for a section nobody is looking at
    /// answered later by mistake.
    @Test("Navigating away clears a screen request nobody has answered yet")
    @MainActor
    func navigatingAwayClearsAnUnansweredScreenRequest() {
        let navigation = AppNavigationState()
        navigation.openScreenRequest(.addMCPServer)

        navigation.open(.section(.activity))

        #expect(navigation.requestedSection == .activity)
        #expect(navigation.requestedScreenRequest == nil)
    }

    @Test("A general Sync route means All Clients")
    @MainActor
    func generalSyncRouteClearsClientScope() {
        let navigation = AppNavigationState()
        navigation.openClient(.gemini)

        navigation.open(.section(.sync))

        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.selectedClient == nil)
    }

    @Test("Brand icons are available as a compiled catalog or source assets")
    @MainActor
    func brandIconsAreAvailableAcrossSwiftToolchains() {
        if ClientBrandAssets.hasCompiledCatalog {
            return
        }

        for client in ClientKind.allCases {
            #expect(ClientBrandAssets.image(for: client, colorScheme: .light) != nil)
            #expect(ClientBrandAssets.image(for: client, colorScheme: .dark) != nil)
        }
    }

    @Test("Queues distinct skill requests in FIFO order")
    @MainActor
    func queuesSkillRequestsInFIFOOrder() {
        let navigation = AppNavigationState()
        let first = UUID()
        let second = UUID()

        navigation.openSkillCreationRequest(first)
        navigation.openSkillCreationRequest(second)
        navigation.openSkillCreationRequest(first)

        #expect(navigation.requestedSection == .skills)
        #expect(navigation.requestedSkillCreationID == first)

        navigation.consumeSkillCreationRequest(second)
        #expect(navigation.requestedSkillCreationID == first)

        navigation.consumeSkillCreationRequest(first)
        #expect(navigation.requestedSkillCreationID == second)

        navigation.consumeSkillCreationRequest(second)
        #expect(navigation.requestedSkillCreationID == nil)
    }

    @Test("Queues external review requests independently in FIFO order")
    @MainActor
    func queuesPendingRequestsInFIFOOrder() {
        let navigation = AppNavigationState()
        let first = UUID()
        let second = UUID()

        navigation.open(.pendingRequest(first))
        navigation.open(.pendingRequest(second))
        navigation.open(.pendingRequest(first))

        #expect(navigation.requestedPendingRequestID == first)
        navigation.consumePendingRequest(second)
        #expect(navigation.requestedPendingRequestID == first)
        navigation.consumePendingRequest(first)
        #expect(navigation.requestedPendingRequestID == second)
        navigation.consumePendingRequest(second)
        #expect(navigation.requestedPendingRequestID == nil)
    }

    @Test("An explicit navigation route clears pending creation requests")
    @MainActor
    func explicitNavigationClearsPendingRequests() {
        let navigation = AppNavigationState()
        navigation.open(.pendingRequest(UUID()))

        navigation.open(.section(.activity))

        #expect(navigation.requestedSection == .activity)
        #expect(navigation.requestedSkillCreationID == nil)
        #expect(navigation.requestedPendingRequestID == nil)
    }

    @Test("Marketplace recommendations select a package without approving an install")
    @MainActor
    func marketplaceRecommendationNavigation() {
        let navigation = AppNavigationState()
        navigation.openMarketplacePackage("mcp-registry:example@1.0.0")

        #expect(navigation.requestedSection == .marketplace)
        #expect(navigation.requestedMarketplacePackageID == "mcp-registry:example@1.0.0")
        #expect(navigation.requestedSkillCreationID == nil)

        navigation.consumeMarketplacePackage("stale")
        #expect(navigation.requestedMarketplacePackageID == "mcp-registry:example@1.0.0")
        navigation.consumeMarketplacePackage("mcp-registry:example@1.0.0")
        #expect(navigation.requestedMarketplacePackageID == nil)
    }

    @Test("A deep link only ever selects; it never approves anything")
    @MainActor
    func skillDeepLinkSelectsWithoutActing() throws {
        let navigation = AppNavigationState()
        let url = try #require(URL(string: "agent-tooling://skills/example-skill"))

        #expect(navigation.open(url: url))

        #expect(navigation.requestedSection == .skills)
        #expect(navigation.requestedSkillID == "example-skill")
        #expect(navigation.requestedPendingRequestID == nil)
    }

    @Test("A URL that is not a route is refused rather than guessed at")
    @MainActor
    func unknownURLsAreRefused() throws {
        let navigation = AppNavigationState()
        for text in [
            "https://example.invalid/skills/example-skill",
            "agent-tooling://nowhere",
            "agent-tooling://skills/one/two",
            "agent-tooling://requests/not-a-uuid",
        ] {
            let url = try #require(URL(string: text))
            #expect(navigation.open(url: url) == false, "\(text)")
        }
        #expect(navigation.requestedSection == nil)
        #expect(navigation.revision == 0)
    }

    /// The two screens that no longer exist still have live external routes.
    /// Neither may dead-end: Configurations asked what a scope requires, which
    /// is now Projects, and Accounts has no screen, so it stops at Apps.
    @Test("Every external route reaches a section that still exists")
    @MainActor
    func everyExternalRouteLands() {
        for section in ExternalAppSection.allCases {
            let navigation = AppNavigationState()
            navigation.open(.section(section))
            let landed = navigation.requestedSection
            #expect(landed != nil, "\(section.rawValue)")
            #expect(landed.map(AppSection.allCases.contains) == true, "\(section.rawValue)")
        }

        let configurations = AppNavigationState()
        configurations.open(.section(.configurations))
        #expect(configurations.requestedSection == .projects)

        let accounts = AppNavigationState()
        accounts.open(.section(.accounts))
        #expect(accounts.requestedSection == .syncCenter)
    }
}

@Suite("Section identity")
struct AppSectionTests {
    @Test("The sidebar shows three groups, and the first is untitled")
    func sidebarGroupsMatchTheInformationArchitecture() {
        #expect(NavigationGroup.allCases.map(\.rawValue) == ["", "Workspace", "Utilities"])
        #expect(NavigationGroup.home.sections == [.overview, .skills, .marketplace])
        #expect(NavigationGroup.manage.sections == [.projects, .syncCenter, .insights])
        #expect(NavigationGroup.operations.sections == [.activity, .settings])
    }

    @Test("The screens the versioned store cannot answer for are gone")
    func retiredSectionsAreAbsent() {
        let names = AppSection.allCases.map(\.rawValue)
        #expect(!names.contains("Configurations"))
        #expect(!names.contains("Accounts"))
        #expect(Set(names).count == names.count)
    }

    @Test("A sidebar row says where it goes, not what it holds")
    func navigationTitlesRenameTheirSections() {
        #expect(AppSection.overview.navigationTitle == "Home")
        #expect(AppSection.skills.navigationTitle == "Library")
        #expect(AppSection.marketplace.navigationTitle == "Discover")
        #expect(AppSection.syncCenter.navigationTitle == "Apps")
        #expect(AppSection.projects.navigationTitle == "Projects")
        #expect(AppSection.insights.navigationTitle == "Insights")
    }

    @Test("Each family lists the same tabs from every one of its members")
    func tabFamiliesAreSymmetric() {
        let families: [[AppSection]] = [
            [.skills, .plugins, .mcpServers, .presets],
            [.syncCenter, .appSettings],
            [.activity, .history],
            [.settings, .sync],
        ]
        for family in families {
            for member in family {
                #expect(member.workspaceTabs == family, "\(member.rawValue)")
            }
        }
        for section in [AppSection.overview, .marketplace, .projects, .insights] {
            #expect(section.workspaceTabs.isEmpty, "\(section.rawValue)")
        }
    }

    /// A tab sits under its family's heading, so it must not repeat it. Only
    /// three tabs disagree with their durable identifier, and each disagrees
    /// because the identifier would read wrongly under that heading.
    @Test("Tab labels read correctly under their own heading")
    func tabTitlesAreScopedToTheirFamily() {
        #expect(AppSection.syncCenter.tabTitle == "Clients")
        #expect(AppSection.appSettings.tabTitle == "Settings")
        #expect(AppSection.settings.tabTitle == "General")
        #expect(AppSection.skills.tabTitle == "Skills")
        #expect(AppSection.presets.tabTitle == "Presets")
        #expect(AppSection.history.tabTitle == "History")
        #expect(AppSection.sync.tabTitle == "Sync")

        #expect(AppSection.skills.workspaceTitle == "Library")
        #expect(AppSection.appSettings.workspaceTitle == "Apps")
        #expect(AppSection.history.workspaceTitle == "Activity")
        #expect(AppSection.sync.workspaceTitle == "Settings")
        #expect(AppSection.overview.workspaceTitle == nil)
    }

    @Test("Every tab keeps its family's sidebar row selected")
    func tabsHighlightTheirFamilyRow() {
        let rows = Set(NavigationGroup.allCases.flatMap(\.sections))
        for section in AppSection.allCases {
            let destination = section.sidebarDestination
            #expect(rows.contains(destination), "\(section.rawValue) → \(destination.rawValue)")
            if section.workspaceTabs.isEmpty {
                #expect(destination == section, "\(section.rawValue)")
            } else {
                #expect(section.workspaceTabs.first == destination, "\(section.rawValue)")
            }
        }
    }

    @Test("No section is unreachable")
    func everySectionIsReachable() {
        let rows = NavigationGroup.allCases.flatMap(\.sections)
        let reachable = Set(rows + rows.flatMap(\.workspaceTabs))
        #expect(reachable == Set(AppSection.allCases))
    }

    @Test("Every section symbol is distinct and exists in this system's catalog")
    @MainActor
    func symbolsAreDistinctAndReal() {
        let symbols = AppSection.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        for section in AppSection.allCases {
            let image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
            #expect(image != nil, "\(section.rawValue) uses \(section.symbol)")
        }
    }
}
