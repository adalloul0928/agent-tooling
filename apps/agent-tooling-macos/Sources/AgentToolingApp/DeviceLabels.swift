import AgentToolingCore
import Foundation

/// The words every screen uses for a Mac in the shared workspace, in one
/// place. Several screens render a device row by hand — "Last seen 25m ago",
/// "Takes only what names it" — and had each retyped the shared parts, so a
/// wording change had to be made in three files or drift. These are the shared
/// parts; each site still composes its own full sentence around them (one
/// adds "· nothing reported yet").
enum DeviceLabels {
    /// A Mac that takes only assignments naming it, not the "every Mac" ones.
    static let limitedMac = "Takes only what names it"
    /// A Mac that has never reported in.
    static let notSeenYet = "Not seen yet"

    /// "Last seen 25m ago", from whatever moment the caller treats as the
    /// device's last contact (its own stamp, or a newer published status).
    static func lastSeen(_ date: Date) -> String {
        "Last seen \(SnapshotTime.compact(date))"
    }

    /// One app's row in another Mac's summary, as the row shows it and as
    /// VoiceOver reads it.
    struct AppLine: Equatable {
        /// The line under the app's name.
        let text: String
        /// The whole row in words. The row's glyph is the only other thing
        /// that tells installed from not found, so the label says which.
        let accessibilityLabel: String
    }

    /// What one app on another Mac holds, by that Mac's own report. The visible
    /// line and the VoiceOver label are joined from the same parts, so they
    /// cannot drift apart, and the parts count in the library's own nouns:
    /// "1 plugin", "2 connections".
    static func appLine(_ app: PublishedDeviceStatus.AppSummary) -> AppLine {
        let name = app.surface.displayName
        guard app.installed else {
            let absent = "not found on that Mac"
            return AppLine(text: absent.capitalizedFirst, accessibilityLabel: "\(name), \(absent)")
        }
        let held = LibraryCounts(
            skills: app.skillCount, plugins: app.pluginCount, connections: app.mcpServerCount
        ).phrases
        return AppLine(
            text: ([app.version ?? "Installed"] + held).joined(separator: " · "),
            accessibilityLabel: ([name, "installed", app.version ?? "version unknown"] + held)
                .joined(separator: ", "))
    }

    /// A library item's kind in the words the app uses for it everywhere,
    /// matching the tile its row draws (`ToolingKind`).
    static func kindName(_ kind: ArtifactKind) -> String {
        switch kind {
        case .skill: CountNoun.skill.singular
        case .mcpServer: CountNoun.connection.singular
        case .nativePlugin, .package: CountNoun.plugin.singular
        case .preset: "preset"
        case .logicalProject: "project"
        }
    }
}

extension DeviceRecord {
    /// "Last seen 25m ago" when the device has reported, "Not seen yet" when it
    /// has not — the detail line a device row shows for its own stamp.
    var lastSeenText: String {
        lastSeenAt.map(DeviceLabels.lastSeen) ?? DeviceLabels.notSeenYet
    }
}
