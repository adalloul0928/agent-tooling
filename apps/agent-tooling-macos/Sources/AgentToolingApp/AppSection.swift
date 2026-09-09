import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case marketplace = "Marketplace"
    case skills = "Skills"
    case insights = "Insights"
    case mcpServers = "Connections"
    case plugins = "Plugins"
    case collections = "Collections"
    case profiles = "Configurations"
    case syncCenter = "Clients"
    case activity = "Activity"
    case projects = "Projects"
    case accounts = "Accounts"
    case settings = "Settings"

    var id: String { rawValue }

    /// Presentation can evolve without changing persisted routes or deep links.
    var navigationTitle: String {
        switch self {
        case .overview: "Home"
        case .skills: "Library"
        case .marketplace: "Discover"
        case .syncCenter: "Apps"
        default: rawValue
        }
    }

    var sidebarDestination: AppSection {
        switch self {
        case .plugins, .mcpServers, .collections: .skills
        case .accounts: .syncCenter
        default: self
        }
    }

    var workspaceTabs: [AppSection] {
        switch self {
        case .skills, .plugins, .mcpServers, .collections: [.skills, .plugins, .mcpServers, .collections]
        case .syncCenter, .accounts: [.syncCenter, .accounts]
        default: []
        }
    }

    var workspaceTitle: String? {
        switch self {
        case .skills, .plugins, .mcpServers, .collections: "Library"
        case .syncCenter, .accounts: "Apps"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .marketplace: "storefront"
        case .skills: "books.vertical"
        case .insights: "lightbulb"
        case .mcpServers: "server.rack"
        case .plugins: "puzzlepiece.extension"
        case .collections: "square.stack.3d.up"
        case .profiles: "slider.horizontal.3"
        case .syncCenter: "desktopcomputer"
        case .activity: "clock.arrow.circlepath"
        case .projects: "folder.badge.gearshape"
        case .accounts: "person.badge.key"
        case .settings: "gearshape"
        }
    }
}

/// Sidebar groups, in display order. The first group has no title.
enum NavigationGroup: String, CaseIterable {
    case home = ""
    case manage = "Workspace"
    case operations = "Utilities"

    var sections: [AppSection] {
        switch self {
        case .home: [.overview, .skills, .marketplace]
        case .manage: [.projects, .profiles, .syncCenter, .insights]
        case .operations: [.activity, .settings]
        }
    }
}
