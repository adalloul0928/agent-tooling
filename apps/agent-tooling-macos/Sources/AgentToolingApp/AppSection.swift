import SwiftUI

/// Every screen the app can show, and the identity that survives a deep link.
///
/// A raw value is a durable identifier, not a caption: `navigationTitle` and
/// `tabTitle` are free to disagree with it, and do, wherever the shelf a person
/// navigates to is named differently from the thing it holds.
enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case marketplace = "Marketplace"
    case skills = "Skills"
    case insights = "Insights"
    case mcpServers = "Connections"
    case plugins = "Plugins"
    case presets = "Presets"
    case syncCenter = "Clients"
    case appSettings = "App settings"
    case activity = "Activity"
    case history = "History"
    case projects = "Projects"
    case settings = "Settings"
    case sync = "Sync"

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

    /// What a tab calls itself inside its own family, where the family name is
    /// already on the heading above it. "Clients" and "Settings" only read
    /// correctly under "Apps"; "General" only reads correctly under "Settings".
    var tabTitle: String {
        switch self {
        case .appSettings: "Settings"
        case .settings: "General"
        default: rawValue
        }
    }

    /// The sidebar row that stays selected while this section is open. Tabs
    /// have no row of their own; they light up the family they belong to.
    var sidebarDestination: AppSection {
        switch self {
        case .plugins, .mcpServers, .presets: .skills
        case .appSettings: .syncCenter
        case .history: .activity
        case .sync: .settings
        default: self
        }
    }

    var workspaceTabs: [AppSection] {
        switch self {
        case .skills, .plugins, .mcpServers, .presets: [.skills, .plugins, .mcpServers, .presets]
        case .syncCenter, .appSettings: [.syncCenter, .appSettings]
        case .activity, .history: [.activity, .history]
        case .settings, .sync: [.settings, .sync]
        default: []
        }
    }

    /// The heading above a family's tabs. A section that stands alone has none,
    /// and its screen keeps whatever title it gave its own toolbar.
    var workspaceTitle: String? {
        switch self {
        case .skills, .plugins, .mcpServers, .presets: "Library"
        case .syncCenter, .appSettings: "Apps"
        case .activity, .history: "Activity"
        case .settings, .sync: "Settings"
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
        case .presets: "square.stack"
        case .syncCenter: "desktopcomputer"
        case .appSettings: "slider.horizontal.3"
        case .activity: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .projects: "folder.badge.gearshape"
        case .settings: "gearshape"
        case .sync: "arrow.triangle.2.circlepath"
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
        case .manage: [.projects, .syncCenter, .insights]
        case .operations: [.activity, .settings]
        }
    }
}
