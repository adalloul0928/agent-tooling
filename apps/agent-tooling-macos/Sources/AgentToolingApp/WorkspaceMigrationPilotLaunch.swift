import AgentToolingCore
import Darwin
import Foundation

/// Explicit migration pilot. A descriptor names one already-prepared attempt;
/// opening it never scans for candidates or adopts the live workspace.
struct WorkspaceMigrationPilotLaunch: Equatable {
    let descriptorURL: URL
    let homeRoot: URL

    static func parse(arguments: [String]) throws -> Self? {
        let flag = "--agent-tooling-migration-review"
        guard !arguments.contains(where: { $0.hasPrefix(flag + "=") }) else { throw PilotError.invalidArguments }
        guard arguments.contains(flag) else { return nil }
        let incompatible = ["--agent-tooling-versioned-preview-root", "--agent-tooling-workspace-id",
                            "--agent-tooling-device-id", "--agent-tooling-workspace"]
        guard !arguments.contains(where: { value in incompatible.contains { value == $0 || value.hasPrefix($0 + "=") } }) else {
            throw PilotError.invalidArguments
        }
        func value(_ name: String) throws -> URL {
            guard !arguments.contains(where: { $0.hasPrefix(name + "=") }) else { throw PilotError.invalidArguments }
            let indices = arguments.indices.filter { arguments[$0] == name }
            guard indices.count == 1, let index = indices.first, arguments.indices.contains(index + 1) else {
                throw PilotError.invalidArguments
            }
            let value = arguments[index + 1]
            guard value.hasPrefix("/"), value != "/",
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw PilotError.invalidArguments
            }
            return URL(fileURLWithPath: value)
        }
        return try .init(descriptorURL: value(flag), homeRoot: value("--agent-tooling-home"))
    }

    @MainActor func openSession() throws -> WorkspaceMigrationReviewSession {
        let location = try readLocation()
        return try WorkspaceMigrationReviewSession(service: WorkspaceMigrationReviewService(location: location), location: location)
    }

    func readLocation() throws -> WorkspaceMigrationReviewLocation {
        var home = stat()
        guard lstat(homeRoot.path, &home) == 0, home.st_mode & S_IFMT == S_IFDIR else { throw PilotError.invalidHome }
        let descriptor = open(descriptorURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw PilotError.invalidDescriptor }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 16 * 1_024 else { throw PilotError.invalidDescriptor }
        let text = try BoundedInputReader.readUTF8(from: handle, maximumBytes: 16 * 1_024)
        return try WorkspaceMigrationReviewLocation.decode(Data(text.utf8))
    }

    enum PilotError: LocalizedError {
        case invalidArguments, invalidDescriptor, invalidHome
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Migration review needs one descriptor file and an explicit home folder. It cannot be combined with another workspace launch."
            case .invalidDescriptor: "The migration review file must be an existing, bounded regular file."
            case .invalidHome: "The migration pilot home folder is unavailable. The live home folder was not substituted."
            }
        }
    }
}
