import Testing

@testable import AgentToolingApp

@Suite("Workspace navigation")
struct WorkspaceNavigationTests {
    @Test("Every existing destination remains reachable from the simplified sidebar")
    func allDestinationsRemainReachable() {
        let sidebar = NavigationGroup.allCases.flatMap(\.sections)
        #expect(Set(sidebar).count == sidebar.count)
        let reachable = Set(sidebar.flatMap { [$0] + $0.workspaceTabs })
        #expect(reachable == Set(AppSection.allCases))
        for destination in AppSection.allCases {
            #expect(sidebar.contains(destination.sidebarDestination))
            if !sidebar.contains(destination) {
                #expect(destination.sidebarDestination.workspaceTabs.contains(destination))
            }
        }
    }

    @Test("Library selection and app account routes keep a stable workspace")
    func childRoutesKeepTheirParentSelected() {
        for route in [AppSection.skills, .plugins, .mcpServers, .collections] {
            #expect(route.sidebarDestination == .skills)
            #expect(route.workspaceTabs == AppSection.skills.workspaceTabs)
        }
        #expect(AppSection.accounts.sidebarDestination == .syncCenter)
        #expect(AppSection.accounts.workspaceTabs == AppSection.syncCenter.workspaceTabs)
        // Labels can change without invalidating persisted route identifiers.
        #expect(AppSection(rawValue: "Marketplace") == .marketplace)
        #expect(AppSection(rawValue: "Clients") == .syncCenter)
        #expect(AppSection.marketplace.navigationTitle == "Discover")
    }
}
