import Foundation
import Observation
import Testing

@testable import AgentToolingCore

@MainActor
struct PersistedObservationTests {
    @Test func metadataCommitDoesNotInvalidateUnchangedInventoryAndHealthViews() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "persisted-observation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(store: WorkspaceStore(rootURL: root), homeURL: root.appending(path: "home"))
        let inventoryChanges = ChangeCounter()
        let preferenceChanges = ChangeCounter()
        withObservationTracking {
            _ = model.skills
            _ = model.plugins
            _ = model.mcpServers
            _ = model.targetObservations
            _ = model.syncStages
            _ = model.activeProfileID
        } onChange: {
            inventoryChanges.increment()
        }
        withObservationTracking {
            _ = model.automaticallyCheckHealth
        } onChange: {
            preferenceChanges.increment()
        }
        let prior = model.currentSnapshot()
        #expect(model.setAutomaticallyCheckHealth(!prior.preferences.automaticallyCheckHealth))
        #expect(preferenceChanges.value == 1)
        #expect(inventoryChanges.value == 0)
        #expect(model.skills == prior.skills)
        #expect(model.targetObservations == prior.targetObservations)
        #expect(
            try model.store.loadWorkspaceSnapshot()?.preferences.automaticallyCheckHealth == !prior.preferences.automaticallyCheckHealth)

        var changed = model.currentSnapshot()
        changed.activeProfileID = "different-selection"
        model.applyPersisted(changed)
        #expect(inventoryChanges.value == 1, "Changed values must still notify existing observers")
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
