import AgentToolingCore
import SwiftUI

/// The pilot starts without a legacy AppModel, so no legacy native/source tasks
/// can be in flight when it selects a store. Production Settings cutover must
/// separately quiesce those operations before exposing this transition there.
struct WorkspaceMigrationPilotHost: View {
    let session: WorkspaceMigrationReviewSession
    let homeRoot: URL
    @State private var library: WorkspaceLibrarySession?
    @State private var legacy: AppModel?
    @State private var navigation = AppNavigationState()
    @State private var errorMessage: String?
    @State private var isOpening = false

    var body: some View {
        VStack(spacing: 0) {
            if library != nil || legacy != nil {
                HStack {
                    Button("Migration review", systemImage: "chevron.left") {
                        library = nil
                        legacy = nil
                    }
                    .buttonStyle(.glass)
                    .disabled(legacy?.isInteractionLocked == true || library?.isBusy == true)
                    Spacer()
                    Text(legacy == nil ? "Migrated library" : "Previous library")
                        .font(.body).foregroundStyle(.secondary)
                }.padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, 10)
                Divider()
            }
            if let library {
                WorkspaceLibraryView(session: library)
            } else if let legacy {
                AppShellView(initialSelection: .overview)
                    .environment(legacy).environment(navigation)
            } else {
                WorkspaceMigrationReviewView(session: session,
                    onOpenLibrary: { Task { await openLibrary() } },
                    onReturnToLegacy: { Task { await openLegacy() } })
                    .disabled(isOpening)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.body).foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @MainActor private func openLibrary() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        errorMessage = nil
        do {
            let location = session.location
            let service = try WorkspaceMigrationReviewService(location: location)
            let state = try await service.state()
            guard let selected = state.authoritySelection, selected.choice == .versioned else {
                throw WorkspaceAuthorityServiceError.notVersioned
            }
            guard let selectedLibrary = try WorkspaceAuthorityLaunch.openWritableSession(legacyRoot: location.legacyRoot) else {
                throw WorkspaceAuthorityServiceError.notVersioned
            }
            library = selectedLibrary
            legacy = nil
        } catch { errorMessage = safeMessage(error) }
    }

    @MainActor private func openLegacy() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        errorMessage = nil
        do {
            let location = session.location
            let state = try await WorkspaceMigrationReviewService(location: location).state()
            guard state.authoritySelection?.choice == .legacy else { throw WorkspaceAuthorityServiceError.invalidSelection }
            legacy = try AppModel(store: WorkspaceStore(rootURL: location.legacyRoot),
                runner: ProcessCommandRunner(homeURL: homeRoot), homeURL: homeRoot)
            library = nil
        } catch { errorMessage = safeMessage(error) }
    }

    private func safeMessage(_ error: any Error) -> String {
        "The selected library could not be opened. Return to the migration review and refresh its status."
    }
}
