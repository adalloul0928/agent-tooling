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
    /// The preset the last successful create produced, so the screen can select
    /// it once the library and this session have caught up with the new row.
    private(set) var lastCreatedPresetID: ArtifactID?

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

    /// Clears the last refusal so a sheet does not open showing an error left
    /// by an earlier attempt.
    func clearError() { errorMessage = nil }

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

    // MARK: - Authoring presets

    /// Creates a preset from library items and selects it once it lands.
    ///
    /// Creating a preset records the shelf; it puts nothing in place. The
    /// members are chosen from what the library already holds, so a member that
    /// is no longer there is refused by the command in words this returns.
    /// Returns true when the preset was recorded.
    @discardableResult
    func createPreset(name: String, memberArtifactIDs: [ArtifactID]) async -> Bool {
        guard canWrite, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        lastCreatedPresetID = nil
        defer { isBusy = false }
        do {
            guard let head = library.state?.snapshot.document.revision.id else {
                errorMessage = "This workspace could not be read. Nothing was created."
                return false
            }
            let command = try CreatePresetCommand(
                expectedRevisionID: head, name: name, memberArtifactIDs: memberArtifactIDs)
            _ = try await service.createPreset(command)
            lastCreatedPresetID = command.presetID
        } catch let refusal as WorkspacePresetCommandError {
            errorMessage = refusal.localizedDescription
            return false
        } catch WorkspaceRevisionStoreError.staleRevision {
            errorMessage = "This workspace changed while you were choosing. Try again."
            return false
        } catch {
            errorMessage = "That preset could not be created. Nothing was changed."
            return false
        }
        await library.refresh()
        reload()
        return true
    }

    /// Renames a preset in place, keeping its members and its following.
    @discardableResult
    func renamePreset(_ presetID: ArtifactID, name: String) async -> Bool {
        guard canWrite, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let head = library.state?.snapshot.document.revision.id else {
                errorMessage = "This workspace could not be read. Nothing was renamed."
                return false
            }
            _ = try await service.renamePreset(
                try RenamePresetCommand(expectedRevisionID: head, presetID: presetID, name: name))
        } catch let refusal as WorkspacePresetCommandError {
            errorMessage = refusal.localizedDescription
            return false
        } catch WorkspaceRevisionStoreError.staleRevision {
            errorMessage = "This workspace changed while you were editing. Try again."
            return false
        } catch {
            errorMessage = "That preset could not be renamed. Nothing was changed."
            return false
        }
        await library.refresh()
        reload()
        return true
    }

    /// Deletes a preset. Its members stay where they are; only the assignments
    /// this preset alone produced are let go of. Stops following it here too, so
    /// this Mac is not left tracking a preset that no longer exists.
    @discardableResult
    func deletePreset(_ presetID: ArtifactID) async -> Bool {
        guard canWrite, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let head = library.state?.snapshot.document.revision.id else {
                errorMessage = "This workspace could not be read. Nothing was deleted."
                return false
            }
            _ = try await service.deletePreset(
                DeletePresetCommand(expectedRevisionID: head, presetID: presetID))
            // The preset is gone, so following it is meaningless; drop this
            // Mac's subscription rather than leaving it pointing at nothing.
            try? store.write(try store.read().filter { $0.presetID != presetID })
        } catch let refusal as WorkspacePresetCommandError {
            errorMessage = refusal.localizedDescription
            return false
        } catch WorkspaceRevisionStoreError.staleRevision {
            errorMessage = "This workspace changed while you were looking. Try again."
            return false
        } catch {
            errorMessage = "That preset could not be deleted. Nothing was changed."
            return false
        }
        await library.refresh()
        reload()
        return true
    }
}
