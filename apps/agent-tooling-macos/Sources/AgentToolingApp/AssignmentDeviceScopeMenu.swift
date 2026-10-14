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

    var body: some View {
        if isShared, registry.count > 1 {
            Menu {
                Section("Except") {
                    ForEach(registry.filter { !$0.isRetired }) { device in
                        Toggle(isOn: Binding(
                            get: { assignment.destination.excludedDeviceIDs?.contains(device.id) == true },
                            set: { excluded in Task { await setExcluded(device.id, excluded) } }
                        )) {
                            Text(device.id == workspace.library.deviceID ? "\(device.name) (this Mac)" : device.name)
                        }
                    }
                }
            } label: {
                Text(label).foregroundStyle(.secondary)
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
        guard let head = try? await workspace.service.snapshot()?.document.revision.id else { return }
        _ = try? await workspace.service.setAssignmentExclusions(.init(
            expectedRevisionID: head, contributionID: assignment.id, excludedDeviceIDs: set.sorted()))
        await workspace.library.refresh()
    }
}
