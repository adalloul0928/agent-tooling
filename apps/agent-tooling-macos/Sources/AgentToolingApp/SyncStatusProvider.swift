import AgentToolingCore
import Foundation

extension WorkspaceLaunch.Workspace {
    /// Installs the shared status provider before any shell or setup sync pass.
    /// Each publish reads current managed-app observations, pending changes, and
    /// sign-in status from sessions; it performs no scan.
    @MainActor
    func installSyncStatusProvider() {
        guard let sync, sync.statusProvider == nil else { return }
        sync.statusProvider = { [weak device, weak library, weak deployment, weak accounts] in
            await MainActor.run {
                guard let device, let library, let deployment else { return nil }
                return PublishedDeviceStatus.current(
                    device: device, library: library, deployment: deployment, accounts: accounts)
            }
        }
    }
}
