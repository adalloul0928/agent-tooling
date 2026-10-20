import Darwin
import Foundation

/// Why a folder could not be bound to a project on this Mac.
///
/// Each case carries the plain words a person should read, because binding a
/// folder is a device-local act somebody performs by hand and the reason it was
/// refused has to make sense without a stack trace behind it.
public enum WorkspaceProjectRootError: Error, Equatable, Sendable, LocalizedError {
    /// The project this binding names is not in the workspace.
    case unknownProject
    /// The path is not absolute, or is not spelled the way this Mac stores one.
    case relativePath
    /// Nothing exists at that path on this Mac.
    case missing
    /// Something exists there, but it is not a folder.
    case notADirectory
    /// The leaf is a symlink. A project folder must be the real directory, so a
    /// later write cannot be redirected somewhere nobody chose.
    case symlink
    /// Another project already uses this exact folder. Its name is carried so
    /// the refusal can say which one, rather than only that there is a clash.
    case folderInUse(otherProjectName: String)

    public var errorDescription: String? {
        switch self {
        case .unknownProject:
            return "This project is not in the workspace. Refresh and try again."
        case .relativePath:
            return "Choose a folder by its full path on this Mac."
        case .missing:
            return "That folder is not on this Mac. Choose one that exists."
        case .notADirectory:
            return "That is a file, not a folder. Choose a folder."
        case .symlink:
            return "That folder is a link to somewhere else. Choose the real folder it points to."
        case .folderInUse(let otherProjectName):
            return "That folder already belongs to “\(otherProjectName)”. A folder can back only one project on this Mac."
        }
    }
}

/// Sets or removes a device-local project folder, excluded from exports.
/// Bindings are one-to-one: rebinding replaces the old folder and rejects
/// folders used by another project. Requires an existing absolute directory
/// without a leaf symlink, using the same containment rules as skill targets.
enum WorkspaceProjectRootCommand {
    /// Records that a project's folder on this Mac is `rootPath`, replacing any
    /// folder it was bound to before. Validates the path against the filesystem
    /// and refuses a folder another project already uses.
    ///
    /// The mutation reads the document handed to it only to name the other
    /// project in a conflict; the caller supplies the same document so the check
    /// runs against the revision being committed.
    static func bind(
        projectID: ArtifactID,
        rootPath: String,
        document: PortableWorkspaceDocument,
        into device: inout DeviceWorkspaceState
    ) throws {
        guard document.logicalProjects.contains(where: { $0.id == projectID }) else {
            throw WorkspaceProjectRootError.unknownProject
        }
        try validatePath(rootPath)

        var roots = device.projectRoots ?? []
        // A folder backs one project only. Naming the other project is what
        // turns a bare refusal into something a person can act on.
        if let clash = roots.first(where: { $0.rootPath == rootPath && $0.projectID != projectID }) {
            let name = document.logicalProjects.first { $0.id == clash.projectID }?.name ?? "another project"
            throw WorkspaceProjectRootError.folderInUse(otherProjectName: name)
        }
        // One binding per project: rebinding is a replacement, not a second row.
        roots.removeAll { $0.projectID == projectID }
        roots.append(.init(projectID: projectID, rootPath: rootPath))
        device.projectRoots = roots
    }

    /// Removes a project's folder binding on this Mac. Nothing on disk is
    /// touched: forgetting a folder only stops this Mac from treating it as the
    /// project's, so a project with no folder is exactly where it started.
    ///
    /// Idempotent: a project that has no binding is left unchanged rather than
    /// treated as an error.
    static func unbind(
        projectID: ArtifactID,
        into device: inout DeviceWorkspaceState
    ) {
        guard var roots = device.projectRoots else { return }
        roots.removeAll { $0.projectID == projectID }
        device.projectRoots = roots
    }

    /// The path must be absolute and spelled the way this Mac stores one, must
    /// point at something that exists, that thing must be a directory, and its
    /// leaf must be the real directory rather than a symlink standing in for it.
    ///
    /// `lstat` is deliberate: it reports the leaf itself, so a symlink is caught
    /// as a symlink rather than followed to whatever it happens to resolve to.
    private static func validatePath(_ rootPath: String) throws {
        do {
            try WorkspaceDomainValidation.requireAbsolutePath(rootPath, field: "device project root")
        } catch {
            throw WorkspaceProjectRootError.relativePath
        }
        var metadata = stat()
        guard lstat(rootPath, &metadata) == 0 else {
            throw WorkspaceProjectRootError.missing
        }
        let kind = metadata.st_mode & S_IFMT
        if kind == S_IFLNK { throw WorkspaceProjectRootError.symlink }
        guard kind == S_IFDIR else { throw WorkspaceProjectRootError.notADirectory }
    }
}
