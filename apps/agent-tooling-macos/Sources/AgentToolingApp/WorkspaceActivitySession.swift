import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// Comparing an installed copy against its reviewed fingerprint means hashing
/// whatever this Mac's ledger points at, which can be anywhere this app has
/// ever installed into.
///
/// A protocol rather than a direct call so a render test can hand in canned
/// reports and never hash a real path on disk — the same reason
/// `WorkspaceDeviceSession` takes its scan behind `DeviceObserving`.
protocol InstallDriftReading: Sendable {
    func drift(in store: WorkspaceRevisionStore) async -> [InstalledPackageDrift]
}

/// The real check: the same comparison the setup check makes.
///
/// Telling a removed install apart from a present one needs only
/// `FileManager`; telling a present install apart from a *modified* one means
/// recomputing the fingerprint recorded when somebody approved it. Both are
/// `InstalledPackageDriftInspector`'s job, and it hashes off the caller's actor
/// itself, so Activity reports exactly what the setup check reports rather than
/// a second opinion that could drift from it.
struct LiveInstallDriftReader: InstallDriftReading {
    func drift(in store: WorkspaceRevisionStore) async -> [InstalledPackageDrift] {
        await InstalledPackageDriftInspector.inspect(store: store)
    }
}

extension EnvironmentValues {
    /// Live by default, so a screen that never overrides this still reads real
    /// drift; a render test overrides it with a reader that never touches disk.
    @Entry var installDriftReader: any InstallDriftReading = LiveInstallDriftReader()
}

/// The journal, the receipts and the drift this Mac has already recorded.
///
/// Everything here is device-local and already written: the journal and the
/// receipts are rows this workspace's own store already holds, and drift is a
/// comparison against what this app itself installed. `refresh()` only reads —
/// nothing here starts a new operation or changes anything on this Mac.
///
/// `WorkspaceLaunch.Workspace` has no session for this, since Activity is one
/// of the screens the versioned store never offered a home for; the section
/// that shows it creates one of these itself, over the workspace's own store.
@MainActor @Observable
final class WorkspaceActivitySession {
    private(set) var receipts: [OperationReceipt] = []
    private(set) var activities: [ActivityReceipt] = []
    private(set) var drift: [InstalledPackageDrift] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    private let store: WorkspaceRevisionStore

    init(store: WorkspaceRevisionStore) {
        self.store = store
    }

    func refresh(driftReader: any InstallDriftReading = LiveInstallDriftReader()) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            receipts = try store.operationReceipts(limit: WorkspaceRevisionStore.maximumReceipts)
            activities = try store.activityJournal(as: AgentActivityJournal.self, default: AgentActivityJournal()).entries
        } catch {
            receipts = []
            activities = []
            errorMessage = "This Mac's activity could not be read."
        }
        // Drift reaches beyond the store's own rows, onto whatever this Mac
        // last installed into, so it goes through the injected reader even
        // though the read above did not need to.
        drift = await driftReader.drift(in: store)
    }

    /// The plan receipt one activity entry points at. Checked against the
    /// loaded page first and read through to the store when it is not there,
    /// so a receipt that rolled off the in-memory list is still reachable.
    func operationReceipt(for id: UUID?) -> OperationReceipt? {
        guard let id else { return nil }
        return receipts.first { $0.id == id } ?? (try? store.operationReceipt(id))
    }
}
