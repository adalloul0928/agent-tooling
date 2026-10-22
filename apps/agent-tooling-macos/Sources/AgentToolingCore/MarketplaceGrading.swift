import Foundation

/// Summaries Agent Tooling writes for itself when a catalog publishes none.
/// Grading has to tell them apart from a real description, so both the code
/// that writes them and the code that grades them read the same list.
enum MarketplaceCopy {
    static let missingRegistryDescription = "No description provided."
    static let installedClaudePlugin = "Installed Claude Code plugin discovered by the native catalog."
    static let availableClaudePlugin = "Available through the current Claude marketplace catalog."
    static let installedCodexPlugin = "Installed Codex plugin discovered by the native catalog."
    static let availableCodexPlugin = "Available through the current Codex plugin catalog."
    static let localPackagePrefix = "Local package with "

    private static let exactGeneratedSummaries: Set<String> = [
        missingRegistryDescription, installedClaudePlugin, availableClaudePlugin, installedCodexPlugin, availableCodexPlugin,
    ]

    /// True when the summary on screen was written by this app rather than by
    /// whoever published the package.
    static func isGeneratedSummary(_ summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if exactGeneratedSummaries.contains(trimmed) { return true }
        return trimmed.hasPrefix(localPackagePrefix)
    }
}

public enum PackageGradeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case license
    case quality
    case maintenance

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .license: "License"
        case .quality: "Quality"
        case .maintenance: "Maintenance"
        }
    }

    /// The label's own qualifier, so a letter is never read as a wider claim
    /// than the thing that was measured.
    public var qualifier: String {
        switch self {
        case .license: "declared license"
        case .quality: "metadata completeness"
        case .maintenance: "listing freshness"
        }
    }

    /// The tooltip. Written in the literal register Glama uses: it says what
    /// was run, and just as plainly what was not.
    public var measurement: String {
        switch self {
        case .license:
            "Reads only the license field this listing declares. Agent Tooling does not read the licence text, check its terms, or confirm the project may be used as stated."
        case .quality:
            "Counts only four things the listing either carries or does not: a description written by the publisher, a version, a source location, and a license. Agent Tooling never starts the server or reads its code, so this is not a verdict on the software."
        case .maintenance:
            "Measures only how long ago the one date this app observed says the package changed — the catalog's own record, or for a folder you added the newest file change on this Mac. Agent Tooling does not read commit history, releases, or issues."
        }
    }
}

public enum PackageGrade: String, Codable, CaseIterable, Sendable {
    case a
    case b
    case c
    case d
    case f

    public var letter: String { rawValue.uppercased() }
}

/// One graded line. A `nil` grade is the honest outcome whenever the input was
/// never observed, and it renders as "Not graded" rather than as a pass.
public struct PackageGradeVerdict: Identifiable, Codable, Hashable, Sendable {
    public static let notGradedLetter = "Not graded"

    public var kind: PackageGradeKind
    public var grade: PackageGrade?
    public var detail: String

    public var id: String { kind.rawValue }

    public init(kind: PackageGradeKind, grade: PackageGrade?, detail: String) {
        self.kind = kind
        self.grade = grade
        self.detail = detail
    }

    public var letter: String { grade?.letter ?? Self.notGradedLetter }
    public var measurement: String { kind.measurement }
}

/// What the last refresh could tell us about the catalog behind a package.
public enum SourceReachability: Hashable, Sendable {
    case reachable(Date)
    case unreachable(String)
    case unknown
}

/// Grades only the three things this app can observe without running anything:
/// the license a listing declares, how complete its metadata is, and how long
/// ago the catalog said it changed. Anything else is left ungraded on purpose.
public enum MarketplaceGrading {
    private enum Age {
        static let a = 90
        static let b = 180
        static let c = 365
        static let d = 730
    }

    private static let recognizedLicenseMarkers = [
        "MIT", "APACHE", "BSD", "ISC", "MPL", "MOZILLA", "GPL", "AGPL", "LGPL", "UNLICENSE", "CC0", "EPL", "ECLIPSE",
        "ZLIB", "BSL", "BOOST", "ARTISTIC", "POSTGRESQL",
    ]

    public static func grades(
        for package: MarketplacePackage,
        reachability: SourceReachability = .unknown,
        asOf now: Date = .now
    ) -> [PackageGradeVerdict] {
        [
            licenseGrade(for: package),
            qualityGrade(for: package),
            maintenanceGrade(for: package, reachability: reachability, asOf: now),
        ]
    }

    private static func licenseGrade(for package: MarketplacePackage) -> PackageGradeVerdict {
        guard let declared = package.license?.trimmingCharacters(in: .whitespacesAndNewlines), !declared.isEmpty else {
            return PackageGradeVerdict(
                kind: .license,
                grade: nil,
                detail: "This listing declares no license, so there is nothing to grade."
            )
        }
        let normalized = declared.uppercased()
        let recognized = recognizedLicenseMarkers.contains { marker in
            normalized.range(of: "\\b\(marker)\\b", options: [.regularExpression]) != nil
        }
        let shown = String(declared.prefix(80))
        return PackageGradeVerdict(
            kind: .license,
            grade: recognized ? .a : .b,
            detail: recognized
                ? "Declares a license this app recognizes by name: \(shown)."
                : "Declares a license, but not in a form this app recognizes by name: \(shown)."
        )
    }

    private static func qualityGrade(for package: MarketplacePackage) -> PackageGradeVerdict {
        let revision = package.revision ?? package.provenance?.lock?.revision
        var missing: [String] = []
        if MarketplaceCopy.isGeneratedSummary(package.summary) { missing.append("a description from the publisher") }
        if !declaresText(revision) { missing.append("a version") }
        if !declaresSpecificLocation(package.location) { missing.append("a source location") }
        if !declaresText(package.license) { missing.append("a license") }

        let present = 4 - missing.count
        let grade: PackageGrade
        switch present {
        case 4: grade = .a
        case 3: grade = .b
        case 2: grade = .c
        case 1: grade = .d
        default: grade = .f
        }
        return PackageGradeVerdict(
            kind: .quality,
            grade: grade,
            detail: missing.isEmpty
                ? "Carries all four fields this app checks: description, version, source location, and license."
                : "Carries \(present) of the four fields this app checks. Missing: \(missing.joined(separator: ", "))."
        )
    }

    private static func maintenanceGrade(
        for package: MarketplacePackage,
        reachability: SourceReachability,
        asOf now: Date
    ) -> PackageGradeVerdict {
        guard let update = package.lastUpdate else {
            switch reachability {
            case .unreachable(let diagnostic):
                return PackageGradeVerdict(
                    kind: .maintenance,
                    grade: nil,
                    detail:
                        "This listing publishes no update date, and its source was unreachable at the last refresh (\(String(diagnostic.prefix(160))))."
                )
            case .reachable, .unknown:
                return PackageGradeVerdict(
                    kind: .maintenance,
                    grade: nil,
                    detail: "This catalog publishes no update date for the listing, so there is nothing to measure."
                )
            }
        }
        let days = max(0, Calendar.current.dateComponents([.day], from: update.date, to: now).day ?? 0)
        let grade: PackageGrade
        switch days {
        case ..<Age.a: grade = .a
        case ..<Age.b: grade = .b
        case ..<Age.c: grade = .c
        case ..<Age.d: grade = .d
        default: grade = .f
        }
        var detail = "Changed \(days) day\(days == 1 ? "" : "s") ago, measured from \(update.summary)"
        if case .unreachable(let diagnostic) = reachability {
            detail += " The source was unreachable at the last refresh (\(String(diagnostic.prefix(160)))), so this date may be stale."
        }
        return PackageGradeVerdict(kind: .maintenance, grade: grade, detail: detail)
    }

    private static func declaresText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A location counts only when it points at something specific. A catalog's
    /// own front door is not a source link.
    private static func declaresSpecificLocation(_ location: String) -> Bool {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return true
        }
        guard ["http", "https"].contains(scheme) else { return true }
        return !components.path.split(separator: "/").isEmpty
    }
}
