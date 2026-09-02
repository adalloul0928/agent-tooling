import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case marketplace = "Marketplace"
    case skills = "Skills"
    case insights = "Insights"
    case mcpServers = "MCP Servers"
    case plugins = "Plugins"
    case collections = "Collections"
    case profiles = "Configurations"
    case syncCenter = "Sync"
    case activity = "Activity"
    case projects = "Projects"
    case accounts = "Accounts"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .marketplace: "storefront"
        case .skills: "doc.text"
        case .insights: "lightbulb"
        case .mcpServers: "server.rack"
        case .plugins: "puzzlepiece.extension"
        case .collections: "square.stack.3d.up"
        case .profiles: "slider.horizontal.3"
        case .syncCenter: "arrow.triangle.2.circlepath"
        case .activity: "clock.arrow.circlepath"
        case .projects: "folder.badge.gearshape"
        case .accounts: "person.badge.key"
        case .settings: "gearshape"
        }
    }

    var navigationGroup: NavigationGroup {
        switch self {
        case .overview, .insights, .marketplace: .home
        case .skills, .plugins, .mcpServers, .collections, .profiles: .manage
        case .projects, .syncCenter, .activity, .accounts, .settings: .operations
        }
    }
}

/// Sidebar groups, in display order. The first group has no title.
enum NavigationGroup: String, CaseIterable {
    case home = ""
    case manage = "Manage"
    case operations = "Operations"

    var sections: [AppSection] {
        switch self {
        case .home: [.overview, .insights, .marketplace]
        case .manage: [.skills, .plugins, .mcpServers, .collections, .profiles]
        case .operations: [.projects, .syncCenter, .activity, .accounts, .settings]
        }
    }
}
