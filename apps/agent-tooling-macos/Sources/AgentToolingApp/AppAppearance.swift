import SwiftUI

/// Light, dark, or whatever macOS is set to: the one appearance choice, under
/// the one key the main window, the setup stage, both Settings pickers and the
/// sidebar's button all read and write. Each takes its key and its tags from
/// here, so a typo in one can no longer silently mean System.
enum AppAppearance: String, CaseIterable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    /// The choice as a picker names it.
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The stored value as a choice. Anything this build does not know is
    /// System, as it always was.
    init(_ stored: String) {
        self = AppAppearance(rawValue: stored) ?? .system
    }

    /// The scheme a window is drawn in, or nil to follow macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The app's own preference keys, kept in the app's defaults rather than a
/// workspace, because they are needed before any workspace exists.
enum AppPreferenceKey {
    static let appearance = "appearance"
    static let showMenuBarItem = "showMenuBarItem"
    static let sidebarCollapsed = "sidebarCollapsed"
}
