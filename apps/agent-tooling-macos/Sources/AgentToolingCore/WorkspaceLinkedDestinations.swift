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

/// Device-local override for an existing portable destination.
/// Destination folders cannot overlap source roots, which would turn deployment
/// into a source edit. `noClobberApplyOnce` refuses occupied paths and preserves
/// their contents.
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
            url.standardizedFileURL.path == path
        else {
            throw WorkspaceLinkedDestinationError.invalidPath
        }
        // The path refusals below are deny checks, so a differently cased
        // spelling of the same folder is refused too, as a case-insensitive
        // volume would treat it.
        let library = managedLibraryRoot.standardizedFileURL.path
        guard !PathContainment.mightBeContained(normalizedChild: path, inNormalizedRoot: library) else {
            throw WorkspaceLinkedDestinationError.pathInsideManagedLibrary
        }
        guard !device.sourceLocations.contains(where: { isWithin(path, or: $0.checkoutPath) }) else {
            throw WorkspaceLinkedDestinationError.pathInUseAsSource
        }
        guard binding(for: selector, in: device) == nil else {
            throw WorkspaceLinkedDestinationError.duplicateSelector
        }
        guard !device.destinations.contains(where: { PathContainment.mightBeSamePath($0.resolvedPath, path) }) else {
            throw WorkspaceLinkedDestinationError.duplicatePath
        }
        device.destinations.append(
            .init(
                id: identifier, selector: selector,
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
    /// inside a source root still writes into that root, and `/` overlaps
    /// every folder.
    private static func isWithin(_ left: String, or right: String) -> Bool {
        PathContainment.overlapsAsGiven(left, right)
    }
}
