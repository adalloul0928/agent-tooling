import AgentToolingCore
import Foundation

/// Explicit development/pilot route, never selected by discovering a database.
/// A malformed preview request fails startup instead of opening the live store.
struct WorkspacePreviewLaunch: Equatable {
    let containerRoot: URL
    let workspaceID: WorkspaceObjectID
    let deviceID: WorkspaceObjectID

    static func parse(arguments: [String]) throws -> Self? {
        let flags = ["--agent-tooling-versioned-preview-root", "--agent-tooling-workspace-id", "--agent-tooling-device-id"]
        guard !arguments.contains(where: { argument in flags.contains(where: { argument.hasPrefix($0 + "=") }) }) else {
            throw PreviewLaunchError.invalidArguments
        }
        guard flags.contains(where: arguments.contains) else { return nil }
        var values: [String] = []
        for flag in flags {
            let indices = arguments.indices.filter { arguments[$0] == flag }
            guard indices.count == 1, let index = indices.first, arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else { throw PreviewLaunchError.invalidArguments }
            values.append(arguments[index + 1])
        }
        guard values[0].hasPrefix("/"), values[0] != "/",
              let workspaceID = UUID(uuidString: values[1]), let deviceID = UUID(uuidString: values[2]) else {
            throw PreviewLaunchError.invalidArguments
        }
        return .init(containerRoot: URL(fileURLWithPath: values[0], isDirectory: true),
                     workspaceID: .init(workspaceID), deviceID: .init(deviceID))
    }

    @MainActor func openSession() throws -> WorkspaceLibrarySession {
        let store = try WorkspaceRevisionStore(containerRoot: containerRoot, workspaceID: workspaceID,
            deviceID: deviceID, access: .existingReadOnly)
        let service = WorkspaceApplicationService(store: store, writerID: WorkspaceObjectID())
        return WorkspaceLibrarySession(service: service, workspaceID: workspaceID, deviceID: deviceID)
    }

    private enum PreviewLaunchError: LocalizedError {
        case invalidArguments
        var errorDescription: String? {
            "Workspace preview needs an existing absolute container path, workspace ID and device ID. The live library was not opened."
        }
    }
}
