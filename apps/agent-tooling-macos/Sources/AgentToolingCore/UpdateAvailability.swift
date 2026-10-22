import Foundation

/// The verdict of one update check. "Up to date" is only ever reached when a
/// tracked source and a reported installed revision were actually compared;
/// everything else is said out loud rather than left silent.
public enum UpdateAvailability: Equatable, Hashable, Sendable {
    case unknown(reason: String)
    case notChecked(reason: String)
    case upToDate(revision: String)
    case updateAvailable(installed: String, available: String)
    case checkFailed(reason: String)
    case sourceMissing(reason: String)

    public var title: String {
        switch self {
        case .unknown: "Update status unknown"
        case .notChecked: "Not checked"
        case .upToDate: "Up to date"
        case .updateAvailable: "Update available"
        case .checkFailed: "Check failed"
        case .sourceMissing: "Source missing"
        }
    }

    public var detail: String {
        switch self {
        case .unknown(let reason), .notChecked(let reason): reason
        case .upToDate(let revision): "Installed revision \(revision) matches its source."
        case .updateAvailable(let installed, let available): "Installed \(installed); the source offers \(available)."
        case .checkFailed(let reason): reason
        case .sourceMissing(let reason): reason
        }
    }

    /// Update available is deliberately the calm clock rather than a warning:
    /// having a newer revision is news, not a fault.
    public var health: HealthState {
        switch self {
        case .unknown, .notChecked: .pending
        case .upToDate: .healthy
        case .updateAvailable: .pending
        case .checkFailed: .attention
        case .sourceMissing: .unavailable
        }
    }

    public var isUpToDate: Bool {
        if case .upToDate = self { return true }
        return false
    }

    public var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    /// A check that could not be completed. It is never reported as health.
    public var isUnverified: Bool {
        switch self {
        case .unknown, .notChecked, .checkFailed, .sourceMissing: true
        case .upToDate, .updateAvailable: false
        }
    }
}

/// A count of each verdict, for a screen that wants one honest sentence.
public struct UpdateAvailabilitySummary: Equatable, Sendable {
    public var unknown = 0
    public var notChecked = 0
    public var upToDate = 0
    public var updateAvailable = 0
    public var checkFailed = 0
    public var sourceMissing = 0

    public init(upToDate: Int = 0, updateAvailable: Int = 0, checkFailed: Int = 0, sourceMissing: Int = 0) {
        self.upToDate = upToDate
        self.updateAvailable = updateAvailable
        self.checkFailed = checkFailed
        self.sourceMissing = sourceMissing
    }

    public var uncheckedCount: Int { checkFailed + sourceMissing + unknown + notChecked }

    /// Only ever states what was measured. Nothing is claimed for items whose
    /// check did not complete.
    public var sentence: String {
        var parts: [String] = []
        if unknown > 0 { parts.append("\(unknown) unknown") }
        if notChecked > 0 { parts.append("\(notChecked) not checked") }
        if updateAvailable > 0 { parts.append("\(updateAvailable) update\(updateAvailable == 1 ? "" : "s") available") }
        if checkFailed > 0 { parts.append("\(checkFailed) check\(checkFailed == 1 ? "" : "s") failed") }
        if sourceMissing > 0 { parts.append("\(sourceMissing) source\(sourceMissing == 1 ? "" : "s") missing") }
        if parts.isEmpty, upToDate > 0 { parts.append("\(upToDate) up to date") }
        return parts.joined(separator: " · ")
    }
}

/// Compares what is installed with what the app has actually recorded about a
/// source. It reads only tracked state, so it never invents a check it did not
/// perform and never touches the network or the filesystem.
public enum UpdateAvailabilityEvaluator {
    public static func evaluate(
        plugin: Plugin,
        sources: [ToolingSource],
        packages: [MarketplacePackage]
    ) -> UpdateAvailability {
        let installed = normalizedRevision(plugin.revision)
        if let package = catalogPackage(for: plugin, in: packages) {
            return evaluate(installed: installed, against: package)
        }
        if let source = trackedSource(for: plugin, in: sources) {
            return evaluate(installed: installed, against: source)
        }
        if plugin.source.hasPrefix("/") {
            return .unknown(
                reason:
                    "\(plugin.name) has no matched update source in this app. Its installed folder has not been reported missing."
            )
        }
        return .unknown(
            reason: "No catalog or reviewed source records where \(plugin.name) came from, so its revision could not be compared."
        )
    }

    public static func evaluate(installed rawInstalled: String?, against package: MarketplacePackage) -> UpdateAvailability {
        let available = normalizedRevision(package.revision)
        switch package.updateStatus {
        case .updateAvailable:
            return .updateAvailable(installed: rawInstalled ?? "an unreported revision", available: available ?? "a newer revision")
        case .locallyModified:
            return .unknown(reason: "Local files differ from \(package.sourceName), so the installed revision cannot be compared.")
        case .conflict:
            return .checkFailed(reason: "\(package.sourceName) reports a source conflict for \(package.name).")
        case .current:
            guard let available else {
                return .unknown(reason: "\(package.sourceName) reported \(package.name) as current without a revision to compare.")
            }
            return .upToDate(revision: available)
        case .unknown, .none:
            break
        }
        guard let installed = rawInstalled else {
            return .unknown(reason: "The app that installed \(package.name) did not report its revision.")
        }
        guard let available else {
            return .unknown(reason: "\(package.sourceName) did not report a revision for \(package.name).")
        }
        guard installed == available || revisionKind(installed) == revisionKind(available) else {
            return .unknown(reason: "The installed Git revision and catalog version use different formats and cannot be compared.")
        }
        return installed == available
            ? .upToDate(revision: available)
            : .updateAvailable(installed: installed, available: available)
    }

    public static func evaluate(installed rawInstalled: String?, against source: ToolingSource) -> UpdateAvailability {
        guard source.lastRefreshedAt != nil else {
            return .notChecked(reason: "\(source.name) has not been checked yet. Refresh Marketplace to compare revisions.")
        }
        guard let available = normalizedRevision(source.lastRevision) else {
            return .unknown(reason: "\(source.name) reported no revision during the last check.")
        }
        guard let installed = rawInstalled else {
            return .unknown(reason: "The installed revision was not reported, so it cannot be compared with \(source.name).")
        }
        guard installed == available || revisionKind(installed) == revisionKind(available) else {
            return .unknown(reason: "The installed Git revision and catalog version use different formats and cannot be compared.")
        }
        return installed == available
            ? .upToDate(revision: available)
            : .updateAvailable(installed: installed, available: available)
    }

    public static func summary(_ values: [UpdateAvailability]) -> UpdateAvailabilitySummary {
        var summary = UpdateAvailabilitySummary()
        for value in values {
            switch value {
            case .unknown: summary.unknown += 1
            case .notChecked: summary.notChecked += 1
            case .upToDate: summary.upToDate += 1
            case .updateAvailable: summary.updateAvailable += 1
            case .checkFailed: summary.checkFailed += 1
            case .sourceMissing: summary.sourceMissing += 1
            }
        }
        return summary
    }

    public static func catalogPackage(for plugin: Plugin, in packages: [MarketplacePackage]) -> MarketplacePackage? {
        let installedClients = Set(plugin.clients.filter(\.reportsLocalPresence).map(\.client))
        let matches = packages.filter { package in
            package.id == plugin.id
                || package.id.hasSuffix(":\(plugin.id)")

        }
        return matches.first { !$0.supportedClients.isDisjoint(with: installedClients) }
    }

    public static func trackedSource(for plugin: Plugin, in sources: [ToolingSource]) -> ToolingSource? {
        let location = plugin.source
        guard !location.isEmpty else { return nil }
        return sources.first { source in
            source.location == location
                || (location.hasPrefix("/") && location.hasPrefix(source.location + "/"))
                || source.name.caseInsensitiveCompare(location) == .orderedSame
        }
    }

    private static func revisionKind(_ value: String) -> String {
        if value.range(of: "^[0-9a-fA-F]{7,40}$", options: .regularExpression) != nil { return "git" }
        if value.range(of: "^v?[0-9]+\\.[0-9]+", options: .regularExpression) != nil { return "version" }
        return "other"
    }

    private static func normalizedRevision(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("unknown") != .orderedSame else { return nil }
        return trimmed
    }
}
