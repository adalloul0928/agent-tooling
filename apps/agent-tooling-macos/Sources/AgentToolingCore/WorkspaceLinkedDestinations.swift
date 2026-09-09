import Foundation

public enum WorkspaceLinkedDestinationError: Error, Equatable, Sendable {
    case invalidPath
    /// That folder is already registered as somewhere bytes come *from*.
    case pathInUseAsSource
    /// Inside this app's own managed library, which it owns entirely.
    case pathInsideManagedLibrary
    /// Two bindings for one destination would each claim the same writes.
    case duplicateSelector
    /// Another destination already writes there.
    case duplicatePath
}

/// Where a destination actually writes on this Mac, when the person pointed it
/// somewhere other than the default.
///
/// A linked destination does not add a new kind of place to install to; it
/// redirects one the workspace already describes. The portable side still says
/// "Codex, user scope" and stays the same on every Mac. Only this device knows
/// it resolves to a folder on an external volume, which is why the binding is
/// device state and never portable bytes.
///
/// Two rules make it safe to point at a folder that is not ours:
///
/// - A path registered as a destination cannot also be a source root. A source
///   root is where authored bytes come from and a destination is where reviewed
///   bytes go; one folder being both is how a deployment quietly becomes an
///   edit to someone's repository.
/// - `noClobberApplyOnce` writes only into a place that holds nothing of ours.
///   Anything already at that path is left exactly as it is and reported, not
///   replaced — this app did not put it there and has no basis for deciding it
///   is disposable.
public enum WorkspaceLinkedDestinations {
    /// Registers a folder for one destination on this device.
    public static func register(
        selector: PortableDestination,
        path: String,
        policy: DestinationWritePolicy = .noClobberApplyOnce,
        in device: inout DeviceWorkspaceState,
        managedLibraryRoot: URL,
        identifier: WorkspaceObjectID = WorkspaceObjectID()
    ) throws {
        let url = URL(fileURLWithPath: path)
        guard url.isFileURL, path.hasPrefix("/"), !path.contains("\0"),
              url.standardizedFileURL.path == path else {
            throw WorkspaceLinkedDestinationError.invalidPath
        }
        let library = managedLibraryRoot.standardizedFileURL.path
        guard path != library, !path.hasPrefix(library + "/") else {
            throw WorkspaceLinkedDestinationError.pathInsideManagedLibrary
        }
        guard !device.sourceLocations.contains(where: { isWithin(path, or: $0.checkoutPath) }) else {
            throw WorkspaceLinkedDestinationError.pathInUseAsSource
        }
        guard binding(for: selector, in: device) == nil else {
            throw WorkspaceLinkedDestinationError.duplicateSelector
        }
        guard !device.destinations.contains(where: { $0.resolvedPath == path }) else {
            throw WorkspaceLinkedDestinationError.duplicatePath
        }
        device.destinations.append(.init(id: identifier, selector: selector,
                                         resolvedPath: path, writePolicy: policy))
    }

    /// Forgets a binding. Nothing at that path is touched: removing what this
    /// app installed there is the reviewed removal path's job, not this one's.
    public static func unregister(_ id: WorkspaceObjectID, in device: inout DeviceWorkspaceState) {
        device.destinations.removeAll { $0.id == id }
    }

    /// The binding for a destination, if this Mac has one.
    ///
    /// Matched on surface, scope and project, so a folder linked for one project
    /// never captures another's writes. Which devices an assignment targets is
    /// not part of it: that says who should have the tool, not where this Mac
    /// puts it.
    public static func binding(
        for destination: PortableDestination,
        in device: DeviceWorkspaceState
    ) -> LinkedDestinationBinding? {
        device.destinations.first {
            $0.selector.surface == destination.surface
                && $0.selector.scope == destination.scope
                && $0.selector.logicalProjectID == destination.logicalProjectID
        }
    }

    /// True when this app may write into `folder` under `policy`.
    ///
    /// `provenInstall` is the caller's own proof that this app put the existing
    /// folder there — ledger or receipt. Without it an existing folder belongs
    /// to whoever made it.
    public static func mayWrite(
        into folder: URL,
        policy: DestinationWritePolicy,
        provenInstall: Bool
    ) -> Bool {
        switch policy {
        case .reviewedReplacement: true
        case .noClobberApplyOnce:
            provenInstall || !FileManager.default.fileExists(atPath: folder.path)
        }
    }

    /// Either path containing the other is the same conflict: a destination
    /// inside a source root still writes into that root.
    private static func isWithin(_ left: String, or right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }
}
