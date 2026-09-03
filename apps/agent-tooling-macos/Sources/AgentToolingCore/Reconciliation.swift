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

struct DesiredState: Codable, Hashable, Sendable {
    var bindings: [ComponentBinding]

}

struct ObservedState: Codable, Hashable, Sendable {
    var bindings: [ComponentBinding]

}

public enum DriftKind: String, Codable, CaseIterable, Sendable {
    case missing
    case unexpected
    case revisionMismatch
    case enablementMismatch
}

public struct Drift: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: DriftKind
    public var desired: ComponentBinding?
    public var observed: ComponentBinding?

    public init(kind: DriftKind, desired: ComponentBinding? = nil, observed: ComponentBinding? = nil) {
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

public struct PlannedOperation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var action: PlannedOperationAction
    public var binding: ComponentBinding
    public var reason: String

    public init(action: PlannedOperationAction, binding: ComponentBinding, reason: String) {
        self.id = "\(action.rawValue):\(binding.id)"
        self.action = action
        self.binding = binding
        self.reason = reason
    }
}

struct ReconciliationPlan: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var drift: [Drift]
    var operations: [PlannedOperation]

    init(id: UUID = UUID(), createdAt: Date = .now, drift: [Drift], operations: [PlannedOperation]) {
        self.id = id
        self.createdAt = createdAt
        self.drift = drift
        self.operations = operations
    }
}

enum ReconciliationPlanner {
    static func plan(desired: DesiredState, observed: ObservedState) -> ReconciliationPlan {
        let desiredByID = indexedBindings(desired.bindings)
        let observedByID = indexedBindings(observed.bindings)
        var drift: [Drift] = []
        var operations: [PlannedOperation] = []

        for id in desiredByID.keys.sorted() {
            guard let wanted = desiredByID[id] else { continue }
            guard let actual = observedByID[id] else {
                drift.append(Drift(kind: .missing, desired: wanted))
                operations.append(
                    PlannedOperation(
                        action: .install,
                        binding: wanted,
                        reason: "The desired component is not installed."
                    ))
                continue
            }
            if let wantedRevision = wanted.revision, actual.revision != wantedRevision {
                drift.append(Drift(kind: .revisionMismatch, desired: wanted, observed: actual))
                operations.append(
                    PlannedOperation(
                        action: .update,
                        binding: wanted,
                        reason: "The installed revision does not match the source lock."
                    ))
            }
            if actual.enabled != wanted.enabled {
                drift.append(Drift(kind: .enablementMismatch, desired: wanted, observed: actual))
                operations.append(
                    PlannedOperation(
                        action: wanted.enabled ? .enable : .disable,
                        binding: wanted,
                        reason: "The client enablement state differs from the profile."
                    ))
            }
        }

        for id in observedByID.keys.sorted() where desiredByID[id] == nil {
            guard let actual = observedByID[id] else { continue }
            drift.append(Drift(kind: .unexpected, observed: actual))
            operations.append(
                PlannedOperation(
                    action: actual.managed ? .remove : .reviewUnmanaged,
                    binding: actual,
                    reason: actual.managed
                        ? "The managed component is no longer present in desired state."
                        : "The component is client-owned or unmanaged and will not be removed automatically."
                ))
        }

        return ReconciliationPlan(
            drift: drift.sorted { lhs, rhs in
                if lhs.id == rhs.id { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.id < rhs.id
            },
            operations: operations.sorted { $0.id < $1.id }
        )
    }

    private static func indexedBindings(_ bindings: [ComponentBinding]) -> [String: ComponentBinding] {
        bindings.sorted { lhs, rhs in
            if lhs.id == rhs.id {
                return (lhs.revision ?? "") < (rhs.revision ?? "")
            }
            return lhs.id < rhs.id
        }.reduce(into: [:]) { result, binding in
            result[binding.id] = binding
        }
    }
}
