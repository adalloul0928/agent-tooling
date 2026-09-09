import AgentToolingCore
import Foundation
import Observation

/// Following a preset, and catching up with one that changed.
///
/// Linking is a standing choice: this Mac keeps the preset's members at the
/// destinations chosen when it was linked. Catching up is never automatic —
/// the changes are shown first, and a destination something else still asks for
/// is named as kept rather than quietly removed.
@MainActor @Observable
final class WorkspacePresetsSession {
    struct Row: Identifiable {
        let id: ArtifactID
        let name: String
        let memberCount: Int
        let subscription: LinkedPresetSubscription?
        let update: LinkedPresetUpdate?
        var isLinked: Bool { subscription != nil }
        /// Something a person would notice would move.
        var hasPendingChanges: Bool { update?.hasPendingChanges == true }
        /// There is work to do, including the invisible kind: a member that
        /// left the preset but stays because you also asked for it yourself
        /// changes nothing on screen, and the preset's own now-stale
        /// contribution still has to be let go of.
        var needsCatchUp: Bool {
            guard let update else { return false }
            return !update.changes.isEmpty || update.fromRevision != update.toRevision
        }
    }

    private(set) var rows: [Row] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var lastAppliedName: String?

    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let store: WorkspaceLinkedPresetStore

    init(service: WorkspaceApplicationService, library: WorkspaceLibrarySession,
         store: WorkspaceLinkedPresetStore) {
        self.service = service
        self.library = library
        self.store = store
    }

    var canWrite: Bool { library.access == .writable }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        reload()
    }

    /// Rebuilds the rows without taking the busy guard, so the actions below
    /// can finish by re-reading rather than leaving the last view on screen.
    private func reload() {
        guard let state = library.state else {
            rows = []
            return
        }
        let subscriptions: [LinkedPresetSubscription]
        do {
            subscriptions = try store.read()
        } catch {
            // Reading nothing would look like everything was unlinked, and the
            // next catch-up would remove real assignments on that basis.
            rows = []
            errorMessage = "This Mac's linked presets could not be read, so none are shown. Nothing was changed."
            return
        }
        let byID = Dictionary(subscriptions.map { ($0.presetID, $0) }, uniquingKeysWith: { first, _ in first })
        rows = state.library.presets.map { preset in
            let subscription = byID[preset.id]
            return .init(
                id: preset.id, name: preset.name, memberCount: preset.memberArtifactIDs.count,
                subscription: subscription,
                update: subscription.flatMap {
                    WorkspaceLinkedPresetResolver.pendingUpdate(for: $0, in: state.snapshot.document)
                })
        }
    }

    /// Starts following a preset at the destinations chosen now.
    ///
    /// Linking records the choice without moving anything: the first catch-up
    /// is shown like any other, so linking never quietly assigns a preset's
    /// members somewhere.
    func link(_ presetID: ArtifactID, destinations: [PortableDestination]) async {
        guard canWrite, !isBusy, !destinations.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            var subscriptions = try store.read().filter { $0.presetID != presetID }
            // Revision 0 is "nothing applied yet", so every current member is
            // shown as an addition rather than assumed to be in place.
            subscriptions.append(.init(presetID: presetID, appliedRevision: 0, destinations: destinations))
            try store.write(subscriptions)
        } catch {
            errorMessage = "This Mac could not record that. Nothing is being followed."
        }
        reload()
    }

    /// Stops following a preset. What it already contributed stays, because
    /// removing it was not what was asked for.
    func unlink(_ presetID: ArtifactID) async {
        guard canWrite, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try store.write(try store.read().filter { $0.presetID != presetID })
        } catch {
            errorMessage = "This Mac could not stop following that preset."
        }
        reload()
    }

    /// Applies exactly the changes shown for one preset.
    func catchUp(_ presetID: ArtifactID) async {
        guard canWrite, !isBusy,
              let row = rows.first(where: { $0.id == presetID }),
              let update = row.update, let subscription = row.subscription,
              let head = library.state?.snapshot.document.revision.id else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            if !update.changes.isEmpty {
                _ = try await service.applyLinkedPresetUpdate(update, expectedRevisionID: head)
            }
            // Recorded only after the change landed, so an interrupted catch-up
            // is offered again rather than being marked done.
            var subscriptions = try store.read().filter { $0.presetID != presetID }
            subscriptions.append(.init(presetID: presetID, appliedRevision: update.toRevision,
                                       destinations: subscription.destinations))
            try store.write(subscriptions)
            lastAppliedName = row.name
        } catch WorkspaceRevisionStoreError.staleRevision {
            errorMessage = "This workspace changed while you were looking. Nothing was applied — check the changes again."
        } catch {
            errorMessage = "That preset could not be caught up with. Nothing was changed."
        }
        await library.refresh()
        reload()
    }
}
