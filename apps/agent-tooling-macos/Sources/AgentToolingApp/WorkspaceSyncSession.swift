import AgentToolingCore
import CryptoKit
import Foundation
import Observation

/// Connects this Mac to a shared workspace repository and runs one sync pass at
/// a time. Every result is reported as observed: a pass that ends in conflicts
/// changed nothing, and a pass that succeeded moved shared intent, never a
/// native client file.
@MainActor @Observable
final class WorkspaceSyncSession {
    private(set) var enrollment: WorkspaceSyncEnrollment?
    private(set) var lastOutcome: WorkspaceSyncOutcome?
    private(set) var conflicts: [WorkspaceMergeConflict] = []
    private(set) var choices: [Int: WorkspaceConflictChoice] = [:]
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// When this Mac last tried, and how many tries in a row failed. Both feed
    /// the scheduler, which is what decides whether a pass may run now.
    private(set) var lastAttempt: Date?
    private(set) var consecutiveFailures = 0
    /// Why the last automatic check did or did not run a pass. Kept so a quiet
    /// scheduler can be explained rather than guessed at.
    private(set) var lastScheduleDecision: WorkspaceSyncScheduleDecision?

    private let store: WorkspaceRevisionStore
    private let enrollmentStore: WorkspaceSyncEnrollmentStore
    private let keyStore: WorkspaceFolderKeyStore?
    private let writerID: WorkspaceObjectID
    private let workspaceID: WorkspaceObjectID
    private var transport: (any WorkspaceRevisionTransport)?

    init(
        store: WorkspaceRevisionStore,
        enrollmentStore: WorkspaceSyncEnrollmentStore,
        workspaceID: WorkspaceObjectID,
        writerID: WorkspaceObjectID,
        keyStore: WorkspaceFolderKeyStore? = nil
    ) {
        self.store = store
        self.enrollmentStore = enrollmentStore
        self.workspaceID = workspaceID
        self.writerID = writerID
        self.keyStore = keyStore
    }

    /// Shown once, right after a folder connection is made: this is the only
    /// way to open that folder from another Mac, and this app cannot show it
    /// again from somewhere else.
    private(set) var recoveryPhrase: String?

    /// Whether this Mac can offer an encrypted folder at all.
    var supportsEncryptedFolder: Bool { keyStore != nil }

    var isConnected: Bool { enrollment != nil }

    /// The person's preference, on unless they turned it off. Being connected
    /// is a separate condition the scheduler checks itself, so that a Mac with
    /// no repository is told it is not connected rather than that automatic
    /// syncing is off — which would be the wrong thing to go looking for.
    var isAutomatic: Bool { enrollment?.isAutomatic ?? true }

    /// How often the automatic check wakes up. Waking is not syncing: each
    /// wake-up asks the scheduler, which spaces real passes much further apart.
    static let checkInterval: Duration = .seconds(60)

    func load() {
        do {
            enrollment = try enrollmentStore.read()
            errorMessage = nil
        } catch {
            enrollment = nil
            errorMessage = "This Mac's sync setup could not be read. Reconnect the repository to continue."
        }
    }

    /// Prepares a dedicated checkout and remembers it for this Mac only.
    func connect(remote: String, checkout: URL, branch: String = "main") async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let record = try WorkspaceSyncEnrollment(
                workspaceID: workspaceID, remote: remote,
                checkoutPath: checkout.standardizedFileURL.path, branch: branch)
            transport = try await GitWorkspaceTransport.enroll(
                remote: record.remote, checkout: checkout, branch: branch)
            try enrollmentStore.write(record)
            enrollment = record
        } catch WorkspaceSyncEnrollmentError.invalidRemote {
            errorMessage = "Enter a repository address without a user name or password in it."
        } catch WorkspaceSyncEnrollmentError.invalidCheckout, GitWorkspaceTransportError.invalidCheckout {
            errorMessage = "Choose a folder on this Mac to hold the workspace repository."
        } catch {
            errorMessage = "That repository could not be prepared on this Mac. Check the address and your access."
        }
    }

    /// Connects a folder a file-sync service already keeps in step.
    ///
    /// `phrase` is empty for the first Mac, which makes a new key and shows it
    /// once. On a second Mac it is the phrase from the first: a new key there
    /// would seal the folder against everything already in it.
    func connectFolder(_ folder: URL, phrase: String) async {
        guard !isBusy, let keyStore else { return }
        isBusy = true
        errorMessage = nil
        recoveryPhrase = nil
        defer { isBusy = false }
        do {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: SymmetricKey
            var isNew = false
            if !trimmed.isEmpty {
                key = try WorkspaceFolderKeyStore.key(fromRecoveryPhrase: trimmed)
            } else if let existing = try keyStore.read() {
                key = existing
            } else {
                key = WorkspaceFolderKeyStore.generate()
                isNew = true
            }
            // Reading before recording: a folder this key cannot open is a
            // wrong key or a wrong folder, and connecting anyway would publish
            // over someone else's sealed workspace.
            let candidate = try EncryptedFolderWorkspaceTransport(
                folder: folder.standardizedFileURL, key: key)
            _ = try await candidate.remoteState()
            let record = try WorkspaceSyncEnrollment(
                workspaceID: workspaceID, remote: "",
                checkoutPath: folder.standardizedFileURL.path, kind: .encryptedFolder)
            try keyStore.write(key)
            try enrollmentStore.write(record)
            transport = candidate
            enrollment = record
            if isNew { recoveryPhrase = WorkspaceFolderKeyStore.recoveryPhrase(for: key) }
        } catch WorkspaceFolderKeyError.invalidRecoveryPhrase {
            errorMessage = "That is not a phrase from another Mac. Copy all of it, exactly as it is shown there."
        } catch EncryptedFolderTransportError.cannotDecrypt {
            errorMessage = "That folder already holds a workspace this phrase does not open. Nothing was changed."
        } catch EncryptedFolderTransportError.invalidFolder,
                WorkspaceSyncEnrollmentError.invalidCheckout {
            errorMessage = "Choose a folder on this Mac that your file sync already keeps in step."
        } catch {
            errorMessage = "That folder could not be used. Nothing was changed."
        }
    }

    /// Stops showing the phrase. It is not stored anywhere it could be shown
    /// again, so this is the point of no return for writing it down.
    func dismissRecoveryPhrase() { recoveryPhrase = nil }

    /// Stops using the repository or folder here. Neither is changed.
    func disconnect() {
        guard !isBusy else { return }
        do {
            try enrollmentStore.remove()
            // The key goes with the connection. Whatever is in the folder stays
            // sealed and stays readable by any Mac that still holds the phrase.
            try keyStore?.remove()
            transport = nil
            enrollment = nil
            lastOutcome = nil
            conflicts = []
            errorMessage = nil
            recoveryPhrase = nil
        } catch {
            errorMessage = "This Mac's sync setup could not be cleared."
        }
    }

    /// Turns automatic passes on or off for this Mac only.
    func setAutomatic(_ value: Bool) {
        guard !isBusy, let enrollment, enrollment.isAutomatic != value else { return }
        do {
            let updated = try enrollment.settingAutomatic(value)
            try enrollmentStore.write(updated)
            self.enrollment = updated
            if !value { lastScheduleDecision = .disabled }
        } catch {
            errorMessage = "This Mac's sync setup could not be updated."
        }
    }

    /// Asks the scheduler whether now is a moment to sync, and syncs if it is.
    ///
    /// The decision is the pure scheduler's, not this class's: passes never
    /// overlap, a run of failures backs off, and an undecided conflict stops
    /// automatic passes entirely, because repeating one would only ask the same
    /// question again.
    @discardableResult
    func runScheduledPass(now: Date = .now) async -> WorkspaceSyncScheduleDecision {
        let decision = WorkspaceSyncScheduler().decide(.init(
            isEnabled: isAutomatic, isConnected: isConnected, isRunning: isBusy,
            hasUnresolvedConflicts: !conflicts.isEmpty, lastAttempt: lastAttempt,
            consecutiveFailures: consecutiveFailures), now: now)
        lastScheduleDecision = decision
        guard decision == .run else { return decision }
        await sync(now: now)
        return decision
    }

    var hasUndecidedConflicts: Bool {
        conflicts.indices.contains { choices[$0] == nil }
    }

    /// Only a conflict that has two sides to pick from can be decided here.
    func canDecide(_ index: Int) -> Bool {
        guard conflicts.indices.contains(index) else { return false }
        // The kind itself says whether picking a side settles it, so this screen
        // cannot offer a chooser for a collision that only a person on the other
        // Mac can undo.
        return conflicts[index].kind.isSettledByChoosingASide
    }

    func choose(_ choice: WorkspaceConflictChoice, at index: Int) {
        guard !isBusy, canDecide(index) else { return }
        choices[index] = choice
    }

    /// Applies every decision at once, against state read fresh at that moment.
    func applyDecisions() async {
        guard !isBusy, !conflicts.isEmpty, !hasUndecidedConflicts, let enrollment else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let resolutions = conflicts.enumerated().compactMap { index, conflict in
            choices[index].map {
                WorkspaceConflictResolution(kind: conflict.kind, artifactID: conflict.artifactID,
                                            objectID: conflict.objectID, choice: $0)
            }
        }
        do {
            let transport = try transport ?? makeTransport(for: enrollment)
            self.transport = transport
            let coordinator = WorkspaceSyncCoordinator(store: store, transport: transport, writerID: writerID)
            let outcome = try await coordinator.resolve(resolutions)
            lastOutcome = outcome
            if case .needsResolution(let values) = outcome {
                // The situation changed; old answers no longer apply to it.
                conflicts = values
                choices = [:]
            } else {
                conflicts = []
                choices = [:]
            }
        } catch {
            errorMessage = "This Mac could not reach the workspace repository. Nothing was changed."
        }
    }

    func sync(now: Date = .now) async {
        guard !isBusy, let enrollment else { return }
        isBusy = true
        errorMessage = nil
        lastAttempt = now
        defer { isBusy = false }
        do {
            let transport = try transport ?? makeTransport(for: enrollment)
            self.transport = transport
            let coordinator = WorkspaceSyncCoordinator(store: store, transport: transport, writerID: writerID)
            let outcome = try await coordinator.sync()
            lastOutcome = outcome
            conflicts = if case .needsResolution(let values) = outcome { values } else { [] }
            choices = [:]
            // A pass that finished is a pass that worked, even when it ended in
            // questions. Only an unreachable repository is a failure to back
            // off from.
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            errorMessage = "This Mac could not reach the workspace repository. Nothing was changed."
        }
    }

    /// Rebuilds the transport this connection describes.
    private func makeTransport(for enrollment: WorkspaceSyncEnrollment) throws -> any WorkspaceRevisionTransport {
        switch enrollment.kind {
        case .git:
            return try GitWorkspaceTransport(
                checkout: URL(fileURLWithPath: enrollment.checkoutPath), branch: enrollment.branch)
        case .encryptedFolder:
            guard let key = try keyStore?.read() else {
                throw WorkspaceSyncEnrollmentError.missingKey
            }
            return try EncryptedFolderWorkspaceTransport(
                folder: URL(fileURLWithPath: enrollment.checkoutPath), key: key)
        }
    }

    /// Why the automatic check is quiet, in the person's terms. `nil` when
    /// there is nothing to explain.
    var scheduleText: String? {
        switch lastScheduleDecision {
        case .none, .run: nil
        case .disabled: "Automatic syncing is off on this Mac."
        case .notConnected: "This Mac is not connected to a repository."
        case .alreadyRunning: "A sync is already running."
        case .waitingForDecisions: "Automatic syncing is paused until you decide the items below."
        case .tooSoon(let next):
            "Next automatic sync \(next.formatted(.relative(presentation: .named)))."
        }
    }

    /// What the last pass did, in the person's terms.
    var statusText: String {
        guard let lastOutcome else {
            return isConnected ? "Not synced on this Mac yet." : "Not connected on this Mac."
        }
        switch lastOutcome {
        case .upToDate: return "Up to date with your other Macs."
        case .published: return "Shared this Mac's setup for the first time."
        case .merged: return "Combined changes from another Mac and shared the result."
        case .adopted: return "Took in changes from another Mac."
        case .needsResolution(let values):
            return values.count == 1
                ? "1 change needs your decision. Nothing was changed."
                : "\(values.count) changes need your decision. Nothing was changed."
        case .remoteMovedDuringSync:
            return "Another Mac published while this one was working. Sync again to finish."
        }
    }
}
