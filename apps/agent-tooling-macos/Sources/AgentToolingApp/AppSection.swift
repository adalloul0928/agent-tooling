import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case marketplace = "Marketplace"
    case skills = "Skills"
    case mcpServers = "MCP Servers"
    case plugins = "Plugins"
    case profiles = "Configurations"
    case syncCenter = "Sync"
    case activity = "Activity"
    case accounts = "Accounts"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .marketplace: "storefront"
        case .skills: "doc.text"
        case .mcpServers: "network"
        case .plugins: "puzzlepiece.extension"
        case .profiles: "person.crop.circle"
        case .syncCenter: "arrow.triangle.2.circlepath"
        case .activity: "clock.arrow.circlepath"
        case .accounts: "person.badge.key"
        case .settings: "gearshape"
        }
    }

    var navigationGroup: NavigationGroup {
        switch self {
        case .overview, .marketplace, .skills, .mcpServers, .plugins, .profiles: .manage
        case .syncCenter, .activity, .accounts, .settings: .operations
        }
    }
}

enum NavigationGroup: String, CaseIterable {
    case manage = "Manage"
    case operations = "Operations"
}
