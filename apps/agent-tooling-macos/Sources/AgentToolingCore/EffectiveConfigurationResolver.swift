import Foundation

/// Where a native setting was written. Ordering is decided per vendor and per
/// installed version, never by one generic rule shared across clients.
public enum ConfigurationLayerKind: String, Codable, Hashable, Sendable, CaseIterable {
    case managedPolicy
    case commandLine
    case session
    case localProject
    case project
    case user
    case builtInDefault
}

/// One parsed configuration file or override set, as read from disk.
public struct ConfigurationLayer: Hashable, Sendable {
    public let kind: ConfigurationLayerKind
    /// Device-local identity of the file this came from, for display only.
    public let sourcePath: String?
    /// Whether this app may write here. Policy and session layers are not ours.
    public let isWritable: Bool
    public let values: [String: ConfigurationValue]
    /// Fields present in the file that this build does not interpret. They are
    /// preserved and reported, never dropped or rewritten.
    public let unrecognizedKeys: [String]

    public init(
        kind: ConfigurationLayerKind,
        sourcePath: String? = nil,
        isWritable: Bool,
        values: [String: ConfigurationValue],
        unrecognizedKeys: [String] = []
    ) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.isWritable = isWritable
        self.values = values
        self.unrecognizedKeys = unrecognizedKeys
    }
}

public enum ConfigurationValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case list([ConfigurationValue])
    /// A value this build can read but not interpret further.
    case opaque(String)

    public var displayText: String {
        switch self {
        case .string(let value): value
        case .number(let value): value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value)) : String(value)
        case .boolean(let value): value ? "On" : "Off"
        case .list(let values): values.map(\.displayText).joined(separator: ", ")
        case .opaque(let value): value
        }
    }
}

/// How several layers contribute to one setting.
public enum ConfigurationMergeRule: String, Hashable, Sendable {
    /// The highest-precedence layer's value replaces the others.
    case replace
    /// Every layer's entries combine, highest precedence first.
    case combineList
}

public struct ConfigurationSettingDefinition: Hashable, Sendable {
    public let key: String
    public let displayName: String
    public let rule: ConfigurationMergeRule
    /// Whether a change takes effect only in a new client session.
    public let requiresNewSession: Bool

    public init(key: String, displayName: String, rule: ConfigurationMergeRule, requiresNewSession: Bool) {
        self.key = key
        self.displayName = displayName
        self.rule = rule
        self.requiresNewSession = requiresNewSession
    }
}

public struct ConfigurationContribution: Hashable, Sendable {
    public let layer: ConfigurationLayerKind
    public let sourcePath: String?
    public let value: ConfigurationValue
    /// True when this layer's value is not what the client will use.
    public let isOverridden: Bool
}

public struct EffectiveConfigurationRow: Hashable, Sendable {
    public let key: String
    public let displayName: String
    public let value: ConfigurationValue
    public let definedBy: ConfigurationLayerKind
    public let definingSourcePath: String?
    /// Every layer that carries this setting, in precedence order.
    public let contributions: [ConfigurationContribution]
    public let rule: ConfigurationMergeRule
    /// The highest-precedence layer this app could write, if any. A value fixed
    /// by policy or a session override is not made editable by having a
    /// writable file underneath it.
    public let writableLayer: ConfigurationLayerKind?
    public let requiresNewSession: Bool
    /// True when a constraining layer means an edit below it cannot take effect.
    public var isConstrained: Bool { writableLayer == nil }
}

/// Every file contributing to one combined setting, in the order the client
/// reads them.
///
/// This exists for `combineList` settings, and for hooks above all. The
/// dangerous misreading of a combined setting is that the highest-precedence
/// file replaced the others — for a value that replaces, it did; for one that
/// combines, every entry is live at once. Somebody who believes their own file
/// overrode a project's hooks believes commands are not running that are.
public struct CombinedSettingBreakdown: Hashable, Sendable {
    public let key: String
    public let displayName: String
    /// Highest precedence first, matching the order the resolver used.
    public let contributions: [Entry]
    /// Every entry across every file. For hooks, the number of things that run.
    public var totalEntryCount: Int { contributions.reduce(0) { $0 + $1.entryCount } }
    public var contributingFileCount: Int { contributions.filter { $0.entryCount > 0 }.count }

    public struct Entry: Hashable, Sendable {
        public let layer: ConfigurationLayerKind
        public let sourcePath: String?
        /// How many items this file contributes. Zero means the key is present
        /// but empty, which is different from the file not mentioning it.
        public let entryCount: Int
    }
}

public struct EffectiveConfiguration: Hashable, Sendable {
    public let surface: TargetSurface
    public let installedClientVersion: String?
    public let rows: [EffectiveConfigurationRow]
    /// Keys present in some layer that this build does not interpret, with the
    /// layer they came from. They are visible, never presented as effective.
    public let unrecognized: [ConfigurationUnrecognizedKey]
    /// Layers this build knows the installed version does not read.
    public let inactiveLayers: [ConfigurationLayerKind]
    /// True when a session or command-line layer could not be observed, so an
    /// effective value can only be described as expected from local files.
    public let sessionOverridesUnknown: Bool

    /// The combined settings, broken down by the file each part came from.
    ///
    /// Only settings whose rule actually combines appear: for a value that
    /// replaces, a breakdown would imply the lower files still matter, and they
    /// do not.
    public var combinedBreakdowns: [CombinedSettingBreakdown] {
        rows.filter { $0.rule == .combineList }.map { row in
            .init(key: row.key, displayName: row.displayName,
                  contributions: row.contributions.map { contribution in
                      .init(layer: contribution.layer, sourcePath: contribution.sourcePath,
                            entryCount: Self.count(contribution.value))
                  })
        }
    }

    private static func count(_ value: ConfigurationValue) -> Int {
        // A list contributes its items; anything else is one thing.
        if case .list(let items) = value { return items.count }
        return 1
    }

    public var summary: String {
        sessionOverridesUnknown
            ? "Expected from local configuration; session overrides unknown."
            : "Effective for new sessions."
    }
}

public struct ConfigurationUnrecognizedKey: Hashable, Sendable {
    public let key: String
    public let layer: ConfigurationLayerKind
    public let sourcePath: String?
}

/// Resolves what a native client will actually use, and why.
///
/// It reads nothing and writes nothing: the caller supplies already-parsed
/// layers, and the result is an explanation rather than a plan. Precedence and
/// per-setting merge rules come from a versioned adapter, so two vendors never
/// share one generic rule. A layer the installed version does not read stays
/// visible but is never counted as effective.
public enum EffectiveConfigurationResolver {
    public static func resolve(
        adapter: some ConfigurationAdapter,
        installedClientVersion: String?,
        layers: [ConfigurationLayer],
        sessionOverridesUnknown: Bool = true
    ) -> EffectiveConfiguration {
        let active = adapter.activeLayers(installedClientVersion: installedClientVersion)
        let order = adapter.precedence(installedClientVersion: installedClientVersion)
        let inactive = layers.map(\.kind).filter { !active.contains($0) }
        let usable = layers.filter { active.contains($0.kind) }
        let byKind = Dictionary(usable.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = order.compactMap { byKind[$0] }

        var rows: [EffectiveConfigurationRow] = []
        for definition in adapter.settings(installedClientVersion: installedClientVersion) {
            let present = ordered.compactMap { layer -> (ConfigurationLayer, ConfigurationValue)? in
                layer.values[definition.key].map { (layer, $0) }
            }
            guard let winner = present.first else { continue }
            let value: ConfigurationValue
            switch definition.rule {
            case .replace:
                value = winner.1
            case .combineList:
                // Hooks and instruction lists add up rather than replace; a
                // lower layer still contributes even when a higher one is set.
                value = .list(present.flatMap { entry -> [ConfigurationValue] in
                    if case .list(let items) = entry.1 { return items }
                    return [entry.1]
                })
            }
            let contributions = present.map { entry in
                ConfigurationContribution(
                    layer: entry.0.kind, sourcePath: entry.0.sourcePath, value: entry.1,
                    isOverridden: definition.rule == .replace && entry.0.kind != winner.0.kind)
            }
            // Only a writable layer at or above the winning one can change what
            // the client uses; writing underneath a fixed value cannot.
            let winningIndex = order.firstIndex(of: winner.0.kind) ?? order.count
            let writable = ordered.first {
                $0.isWritable && (order.firstIndex(of: $0.kind) ?? order.count) <= winningIndex
            }?.kind ?? (definition.rule == .combineList
                ? ordered.first(where: \.isWritable)?.kind : nil)
            rows.append(.init(
                key: definition.key, displayName: definition.displayName, value: value,
                definedBy: winner.0.kind, definingSourcePath: winner.0.sourcePath,
                contributions: contributions, rule: definition.rule,
                writableLayer: writable, requiresNewSession: definition.requiresNewSession))
        }

        // Anything present in a file that this adapter has no definition for is
        // reported rather than dropped, alongside what the reader already knew
        // it could not interpret.
        let defined = Set(adapter.settings(installedClientVersion: installedClientVersion).map(\.key))
        let unrecognized = layers.flatMap { layer in
            (layer.unrecognizedKeys + layer.values.keys.filter { !defined.contains($0) })
                .reduce(into: [String]()) { result, key in
                    if !result.contains(key) { result.append(key) }
                }
                .sorted()
                .map { ConfigurationUnrecognizedKey(key: $0, layer: layer.kind, sourcePath: layer.sourcePath) }
        }
        return .init(
            surface: adapter.surface, installedClientVersion: installedClientVersion,
            rows: rows.sorted { $0.key < $1.key },
            unrecognized: unrecognized,
            inactiveLayers: Array(Set(inactive)).sorted { $0.rawValue < $1.rawValue },
            sessionOverridesUnknown: sessionOverridesUnknown)
    }
}

/// One vendor's rules at one installed version. Adding a client means adding an
/// adapter with its own tested precedence, never widening a shared one.
public protocol ConfigurationAdapter: Sendable {
    var surface: TargetSurface { get }
    /// Highest precedence first.
    func precedence(installedClientVersion: String?) -> [ConfigurationLayerKind]
    /// Layers the installed version actually reads.
    func activeLayers(installedClientVersion: String?) -> Set<ConfigurationLayerKind>
    func settings(installedClientVersion: String?) -> [ConfigurationSettingDefinition]
}
