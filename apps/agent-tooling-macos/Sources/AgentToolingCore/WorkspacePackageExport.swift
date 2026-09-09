import Foundation

public enum WorkspacePackageExportError: Error, Equatable, Sendable {
    case invalidDestination
    case destinationNotEmpty
    case missingContent
    case unsupportedEntry
    case writeFailed
}

/// Something a target cannot consume, named rather than dropped silently.
public struct PackageCompatibilityNote: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The package declares an MCP transport this target does not support.
        case unsupportedTransport
        /// The package carries components this target has no place for.
        case unsupportedComponent
        /// A file the package needs is produced by a native adapter, not here.
        case nativeAdapterDependency
        /// Executable content whose behavior the receiver must review.
        case executableContent
    }
    public let kind: Kind
    public let detail: String
    /// The package-relative file this note is about, when it names one.
    public let relativePath: String?
}

/// One target's ability to consume this exact package.
public struct PackageCompatibilityReport: Hashable, Sendable {
    public let surface: TargetSurface
    public let notes: [PackageCompatibilityNote]
    /// True only when nothing in the package is unsupported at this target.
    public var isFullySupported: Bool {
        !notes.contains { $0.kind == .unsupportedTransport || $0.kind == .unsupportedComponent }
    }
}

public struct WorkspacePackageExport: Hashable, Sendable {
    public let artifactID: ArtifactID
    public let declaredName: String
    public let digest: ContentDigest
    public let fileCount: Int
    public let totalFileBytes: Int
    /// Every target asked about, whether or not it can consume the package.
    public let compatibility: [PackageCompatibilityReport]
    /// Files carried verbatim, including resources, scripts and unknown vendor
    /// extensions. Nothing is translated.
    public let relativePaths: [String]
}

/// Writes a complete package folder and explains what each target can do with
/// it. Every byte is carried verbatim: resources, scripts, empty directories,
/// internal links and unknown vendor files all survive, and nothing is
/// translated between vendors.
///
/// A compatibility note is not a repair. Anything a target cannot consume is
/// named in the report and left in the export.
///
/// Links that leave the package need no note: `CapturedPackageTree` refuses
/// them, so a tree that reaches here already resolves within itself.
public enum WorkspacePackageExporter {
    /// Describes an export without writing anything.
    public static func preview(
        artifact: ArtifactRecord,
        tree: CapturedPackageTree,
        targets: [TargetCapabilityEvidence],
        declaredTransports: [String] = []
    ) -> WorkspacePackageExport {
        let files = tree.entries.filter { if case .file = $0.kind { true } else { false } }
        let executables = tree.entries.filter {
            if case .file(_, let executable) = $0.kind { executable } else { false }
        }
        let surfaces = Array(Set(targets.map(\.surface))).sorted { $0.rawValue < $1.rawValue }
        let reports = surfaces.map { surface -> PackageCompatibilityReport in
            let evidence = targets.filter { $0.surface == surface }
            var notes: [PackageCompatibilityNote] = []
            let supportedComponents = Set(evidence.filter { $0.support == .supported }.map(\.component))
            let component = self.component(for: artifact.identity.kind)
            if let component, !supportedComponents.contains(component) {
                notes.append(.init(kind: .unsupportedComponent,
                    detail: "This target does not accept this kind of package.", relativePath: nil))
            }
            for transport in declaredTransports.sorted() {
                let supported = evidence.contains {
                    $0.component == .mcpServer && $0.transport == transport && $0.support == .supported
                }
                if !supported {
                    notes.append(.init(kind: .unsupportedTransport,
                        detail: "This target does not support the \(transport) connection type.",
                        relativePath: nil))
                }
            }
            if artifact.authority == .nativeOwned {
                notes.append(.init(kind: .nativeAdapterDependency,
                    detail: "This package is installed and updated by its own app, not from an export.",
                    relativePath: nil))
            }
            for entry in executables.sorted(by: { $0.relativePath < $1.relativePath }) {
                notes.append(.init(kind: .executableContent,
                    detail: "This file runs when the package is used. Review it before trusting it.",
                    relativePath: entry.relativePath))
            }
            return .init(surface: surface, notes: notes)
        }
        return .init(
            artifactID: artifact.identity.id,
            declaredName: artifact.declaredName ?? artifact.identity.displayName,
            digest: tree.digest,
            fileCount: files.count,
            totalFileBytes: tree.totalFileBytes,
            compatibility: reports,
            relativePaths: tree.entries.map(\.relativePath).sorted())
    }

    /// Writes the package into a new directory the caller names. It refuses an
    /// existing non-empty destination rather than merging into it.
    public static func write(
        tree: CapturedPackageTree,
        to destination: URL
    ) throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              !destination.path.contains("\0"),
              destination.standardizedFileURL.path == destination.path else {
            throw WorkspacePackageExportError.invalidDestination
        }
        let manager = FileManager.default
        if let existing = try? manager.contentsOfDirectory(atPath: destination.path), !existing.isEmpty {
            throw WorkspacePackageExportError.destinationNotEmpty
        }
        do {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch { throw WorkspacePackageExportError.writeFailed }

        // Directories first, so a file never creates its own parent implicitly
        // and an empty directory in the package survives the round trip.
        for entry in tree.entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            let url = destination.appending(path: entry.relativePath)
            guard url.standardizedFileURL.path.hasPrefix(destination.path + "/") else {
                throw WorkspacePackageExportError.invalidDestination
            }
            do {
                switch entry.kind {
                case .directory:
                    try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                case .file(let bytes, let executable):
                    try manager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                    try bytes.write(to: url, options: .withoutOverwriting)
                    try manager.setAttributes([.posixPermissions: executable ? 0o700 : 0o600],
                                              ofItemAtPath: url.path)
                case .symbolicLink(let target):
                    try manager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                    try manager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                }
            } catch { throw WorkspacePackageExportError.writeFailed }
        }
    }

    private static func component(for kind: ArtifactKind) -> ComponentKind? {
        switch kind {
        case .skill: .skill
        case .mcpServer: .mcpServer
        case .nativePlugin, .package: .plugin
        case .preset, .logicalProject: nil
        }
    }
}
