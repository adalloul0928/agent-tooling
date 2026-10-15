import Foundation

public struct ComponentBinding: Identifiable, Codable, Hashable, Sendable {
    public var package: PackageIdentity
    public var componentID: String
    public var kind: ComponentKind
    public var target: TargetSurface
    public var scope: ToolingScope
    public var revision: String?
    public var enabled: Bool
    public var managed: Bool

    public init(
        package: PackageIdentity,
        componentID: String,
        kind: ComponentKind,
        target: TargetSurface,
        scope: ToolingScope,
        revision: String? = nil,
        enabled: Bool = true,
        managed: Bool = true
    ) {
        self.package = package
        self.componentID = componentID
        self.kind = kind
        self.target = target
        self.scope = scope
        self.revision = revision
        self.enabled = enabled
        self.managed = managed
    }

    public var id: String { "\(package.name):\(kind.rawValue):\(componentID):\(target.rawValue):\(scope.rawValue)" }
}

public enum DriftKind: String, Codable, CaseIterable, Sendable {
    case missing
    case unexpected
    case revisionMismatch
    case enablementMismatch
}

struct Drift: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var kind: DriftKind
    var desired: ComponentBinding?
    var observed: ComponentBinding?

    init(kind: DriftKind, desired: ComponentBinding? = nil, observed: ComponentBinding? = nil) {
        self.kind = kind
        self.desired = desired
        self.observed = observed
        self.id = desired?.id ?? observed?.id ?? UUID().uuidString
    }
}

public enum PlannedOperationAction: String, Codable, CaseIterable, Sendable {
    case install
    case update
    case enable
    case disable
    case remove
    case reviewUnmanaged
}
