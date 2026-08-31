import Testing

@testable import AgentToolingCore

struct ReconciliationPlannerTests {
    @Test func plannerProducesDeterministicReviewableOperations() {
        let wanted = binding(name: "portable", revision: "new", enabled: true, managed: true)
        var stale = wanted
        stale.revision = "old"
        stale.enabled = false
        let unmanaged = binding(name: "manual", revision: nil, enabled: true, managed: false)

        let plan = ReconciliationPlanner.plan(
            desired: DesiredState(bindings: [wanted]),
            observed: ObservedState(bindings: [unmanaged, stale])
        )

        #expect(plan.drift.map(\.kind) == [.unexpected, .enablementMismatch, .revisionMismatch])
        #expect(plan.operations.map(\.action) == [.enable, .reviewUnmanaged, .update])
        #expect(plan.operations.contains(where: { $0.action == .reviewUnmanaged && $0.binding == unmanaged }))
    }

    @Test func duplicateBindingsCannotCrashPlanning() {
        let older = binding(name: "portable", revision: "1", enabled: true, managed: true)
        let newer = binding(name: "portable", revision: "2", enabled: true, managed: true)

        let plan = ReconciliationPlanner.plan(
            desired: DesiredState(bindings: [newer, older]),
            observed: ObservedState(bindings: [])
        )

        #expect(plan.operations.count == 1)
        #expect(plan.operations.first?.binding.revision == "2")
    }

    private func binding(
        name: String,
        revision: String?,
        enabled: Bool,
        managed: Bool
    ) -> ComponentBinding {
        ComponentBinding(
            package: PackageIdentity(name: name),
            componentID: "skill",
            kind: .skill,
            target: .codexCLI,
            scope: .user,
            revision: revision,
            enabled: enabled,
            managed: managed
        )
    }
}
