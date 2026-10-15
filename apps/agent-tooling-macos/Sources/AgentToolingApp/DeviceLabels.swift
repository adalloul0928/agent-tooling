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
}

extension DeviceRecord {
    /// "Last seen 25m ago" when the device has reported, "Not seen yet" when it
    /// has not — the detail line a device row shows for its own stamp.
    var lastSeenText: String {
        lastSeenAt.map(DeviceLabels.lastSeen) ?? DeviceLabels.notSeenYet
    }
}
