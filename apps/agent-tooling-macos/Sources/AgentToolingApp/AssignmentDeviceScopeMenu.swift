import AgentToolingCore
import SwiftUI

/// One saved assignment's Macs, as a label with a way to change the exceptions.
///
/// "Every Mac" is the shared default; this is where one item is kept off one
/// Mac without touching the rest. An assignment that names Macs is shown as
/// is: changing it means assigning again from the picker.
struct AssignmentDeviceScopeMenu: View {
    let assignment: WorkspaceLibraryRequestedAssignment
    let workspace: WorkspaceLaunch.Workspace

    private var registry: [DeviceRecord] {
        workspace.library.state?.snapshot.document.deviceRegistry ?? []
    }

    private var isShared: Bool { assignment.destination.deviceIDs == nil }

    @State private var errorMessage: String?

    var body: some View {
        if isShared, registry.count > 1 {
            Menu {
                Section("Except") {
                    ForEach(registry.filter { !$0.isRetired }) { device in
                        ExceptToggle(
                            title: device.id == workspace.library.deviceID ? "\(device.name) (this Mac)" : device.name,
                            isExcluded: assignment.destination.excludedDeviceIDs?.contains(device.id) == true,
                            set: { excluded in await setExcluded(device.id, excluded) })
                    }
                }
            } label: {
                HStack(spacing: Space.xs) {
                    Text(label).foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(AgentFont.caption).foregroundStyle(AgentTheme.failure)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(workspace.library.isBusy || workspace.library.access != .writable)
            .help("Which Macs this shared assignment leaves out.")
        } else {
            Text(label).foregroundStyle(.secondary)
        }
    }

    private var label: String {
        let names = Dictionary(registry.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        switch assignment.destination.deviceIDs {
        case nil:
            let excluded = (assignment.destination.excludedDeviceIDs ?? []).compactMap { names[$0] }
            return excluded.isEmpty ? "Every Mac" : "Every Mac except \(excluded.formatted(.list(type: .and)))"
        case []:
            return "No Macs"
        case let ids?:
            let listed = ids.map { names[$0] ?? ($0 == workspace.library.deviceID ? "This Mac" : "another Mac") }
            return ids == [workspace.library.deviceID] ? "This Mac only" : listed.formatted(.list(type: .and))
        }
    }

    private func setExcluded(_ device: WorkspaceObjectID, _ excluded: Bool) async {
        var set = Set(assignment.destination.excludedDeviceIDs ?? [])
        if excluded { set.insert(device) } else { set.remove(device) }
        errorMessage = nil
        do {
            guard let head = try await workspace.service.snapshot()?.document.revision.id else { return }
            _ = try await workspace.service.setAssignmentExclusions(
                .init(
                    expectedRevisionID: head, contributionID: assignment.id, excludedDeviceIDs: set.sorted()))
        } catch {
            // Most often the library moved under us; the menu shows the saved
            // scope again once the refresh lands, and the person can retry.
            errorMessage = "That change was not saved. Try again."
        }
        await workspace.library.refresh()
    }
}

/// One Mac's row in the Except menu. A separate view so the toggle's binding
/// is typed once, where the compiler can see it.
private struct ExceptToggle: View {
    let title: String
    let isExcluded: Bool
    let set: @MainActor @Sendable (Bool) async -> Void

    var body: some View {
        Toggle(
            title,
            isOn: Binding(
                get: { isExcluded },
                set: { excluded in Task { await set(excluded) } }))
    }
}
