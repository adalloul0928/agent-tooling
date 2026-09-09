import CryptoKit
import Darwin
import Foundation

public enum WorkspaceSkillTargetCaptureError: Error, Equatable, Sendable {
    case invalidSelectors
    case unsupportedSurface(TargetSurface)
    case invalidProjectBindings
    case missingProject(ArtifactID)
    case missingObservation(TargetSurface)
    case ambiguousObservation(TargetSurface)
    case unavailableClient(TargetSurface)
    case invalidRoot
    case unreadableDirectory
    case changedDuringCapture
}

/// Device-local evidence. A canonical directory identity is useful for merging
/// overlapping assignments; it does not authorize a filesystem write. The
/// reviewed operation must capture its own destination baseline before applying.
public struct CapturedSkillAssignmentTarget: Hashable, Sendable {
    public let target: ResolvedAssignmentTarget
    public let plannedDirectory: URL
    public let canonicalDirectory: URL
}

/// Resolves the native CLI skill routes on this device. Capability support is
/// deliberately supplied separately to WorkspaceAssignmentResolver: an installed
/// client, version string, or generic supportsProjectScope flag is not a probe.
public enum WorkspaceSkillTargetCapture {
    public static let adapterContractVersion: UInt = 1

    public static func capture(
        homeURL: URL,
        deviceID: WorkspaceObjectID,
        selectors: [ResolvedAssignmentSelector],
        projectRoots: [DeviceProjectRootBinding] = [],
        observations: [TargetObservation],
        /// What this Mac recorded each client can accept. Empty means a target
        /// carries skills only, which is what it did before this existed.
        capabilityEvidence: [TargetCapabilityEvidence] = []
    ) async throws -> [CapturedSkillAssignmentTarget] {
        let task = Task.detached(priority: .utility) {
            try captureSynchronously(homeURL: homeURL, deviceID: deviceID, selectors: selectors,
                projectRoots: projectRoots, observations: observations,
                capabilityEvidence: capabilityEvidence)
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    /// What this target can carry, from what this Mac actually observed.
    ///
    /// Skills are always here: a captured skill destination is what this type
    /// is for, and the resolver's own rules decide whether one may be placed.
    /// Anything else appears only where there is supported evidence for that
    /// component, at that scope, from the version that was observed. Listing a
    /// component with no evidence behind it would let a plan form for something
    /// this Mac never saw a client accept.
    static func componentContexts(
        surface: TargetSurface, scope: ToolingScope, version: String?,
        evidence: [TargetCapabilityEvidence]
    ) -> [ResolvedTargetComponentContext] {
        var contexts: [ResolvedTargetComponentContext] = [.init(component: .skill)]
        for entry in evidence
        where entry.surface == surface
            && entry.component != .skill
            && entry.scopes.contains(scope)
            && entry.installedClientVersion == version
            && entry.support == .supported {
            let context = ResolvedTargetComponentContext(component: entry.component,
                                                         transport: entry.transport)
            if !contexts.contains(context) { contexts.append(context) }
        }
        return contexts
    }

    private static func captureSynchronously(
        homeURL: URL, deviceID: WorkspaceObjectID, selectors: [ResolvedAssignmentSelector],
        projectRoots: [DeviceProjectRootBinding], observations: [TargetObservation],
        capabilityEvidence: [TargetCapabilityEvidence]
    ) throws -> [CapturedSkillAssignmentTarget] {
        try Task.checkCancellation()
        guard selectors.count <= 1_024, Set(selectors).count == selectors.count,
              observations.count <= 1_024 else { throw WorkspaceSkillTargetCaptureError.invalidSelectors }
        guard projectRoots.count <= 10_000,
              Set(projectRoots.map(\.projectID)).count == projectRoots.count else {
            throw WorkspaceSkillTargetCaptureError.invalidProjectBindings
        }
        let homeBinding = try existingRoot(homeURL, rejectLeafSymlink: false)
        let projects = Dictionary(uniqueKeysWithValues: projectRoots.map { ($0.projectID, $0.rootPath) })
        var rootBindings = [(homeURL, homeBinding)]
        var directoryBindings: [(URL, DirectoryBinding)] = []
        var results: [CapturedSkillAssignmentTarget] = []
        for selector in selectors {
            try Task.checkCancellation()
            let client: ClientKind
            switch selector.surface {
            case .claudeCode: client = .claude
            case .codexCLI: client = .codex
            case .geminiCLI: client = .gemini
            default: throw WorkspaceSkillTargetCaptureError.unsupportedSurface(selector.surface)
            }
            let projectRoot: URL?
            switch selector.scope {
            case .user:
                guard selector.logicalProjectID == nil else { throw WorkspaceSkillTargetCaptureError.invalidSelectors }
                projectRoot = nil
            case .project:
                guard let id = selector.logicalProjectID else { throw WorkspaceSkillTargetCaptureError.invalidSelectors }
                guard let path = projects[id] else { throw WorkspaceSkillTargetCaptureError.missingProject(id) }
                guard path.hasPrefix("/") else { throw WorkspaceSkillTargetCaptureError.invalidRoot }
                let root = URL(fileURLWithPath: path, isDirectory: true)
                let binding = try existingRoot(root, rejectLeafSymlink: true)
                rootBindings.append((root, binding))
                // Match the legacy planner's resolved project root. Home routes
                // keep their original spelling; their physical identity is separate.
                projectRoot = root.resolvingSymlinksInPath().standardizedFileURL
            default: throw WorkspaceSkillTargetCaptureError.invalidSelectors
            }
            let matches = observations.filter { $0.surface == selector.surface }
            guard matches.count <= 1 else { throw WorkspaceSkillTargetCaptureError.ambiguousObservation(selector.surface) }
            guard let observation = matches.first else { throw WorkspaceSkillTargetCaptureError.missingObservation(selector.surface) }
            guard observation.installed else { throw WorkspaceSkillTargetCaptureError.unavailableClient(selector.surface) }
            let directory = try NativeSkillDestination.directory(
                client: client, homeURL: homeURL, scope: selector.scope, projectRoot: projectRoot)
            let binding = try directoryBinding(directory)
            directoryBindings.append((directory, binding))
            results.append(.init(target: .init(selector: selector,
                physicalDestinationID: identity(deviceID: deviceID, directory: binding.canonicalDirectory),
                installedClientVersion: observation.version, adapterContractVersion: adapterContractVersion,
                componentContexts: componentContexts(
                    surface: selector.surface, scope: selector.scope,
                    version: observation.version, evidence: capabilityEvidence)),
                plannedDirectory: directory, canonicalDirectory: binding.canonicalDirectory))
        }
        // Detect ordinary replacement and newly-created missing suffixes across
        // the capture. This is observation consistency, not snapshot isolation.
        for (url, before) in rootBindings + directoryBindings {
            try Task.checkCancellation()
            guard try directoryBinding(url) == before else { throw WorkspaceSkillTargetCaptureError.changedDuringCapture }
        }
        return results
    }

    private struct DirectoryBinding: Equatable {
        let canonicalDirectory: URL
        let anchorDevice: dev_t
        let anchorInode: ino_t
        let missingComponents: [String]
    }

    private static func existingRoot(_ url: URL, rejectLeafSymlink: Bool) throws -> DirectoryBinding {
        if rejectLeafSymlink {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) != S_IFLNK else {
                throw WorkspaceSkillTargetCaptureError.invalidRoot
            }
        }
        let result = try directoryBinding(url)
        guard result.missingComponents.isEmpty else { throw WorkspaceSkillTargetCaptureError.invalidRoot }
        return result
    }

    private static func directoryBinding(_ url: URL) throws -> DirectoryBinding {
        guard NativeSkillDestination.isValidRoot(url) else {
            throw WorkspaceSkillTargetCaptureError.invalidRoot
        }
        var anchor = url
        var missing: [String] = []
        while true {
            try Task.checkCancellation()
            let descriptor = open(anchor.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if descriptor >= 0 {
                defer { close(descriptor) }
                var metadata = stat()
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fstat(descriptor, &metadata) == 0, fcntl(descriptor, F_GETPATH, &path) == 0 else {
                    throw WorkspaceSkillTargetCaptureError.unreadableDirectory
                }
                guard let name = String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                    throw WorkspaceSkillTargetCaptureError.unreadableDirectory
                }
                var canonical = URL(fileURLWithPath: name, isDirectory: true)
                for part in missing.reversed() { canonical.append(path: part, directoryHint: .isDirectory) }
                return .init(canonicalDirectory: canonical, anchorDevice: metadata.st_dev,
                    anchorInode: metadata.st_ino, missingComponents: missing)
            }
            guard errno == ENOENT, anchor.path != "/" else {
                throw WorkspaceSkillTargetCaptureError.unreadableDirectory
            }
            // A dangling link is an existing conflicting entry, not a missing
            // directory we can append to a parent. Never project through it.
            var metadata = stat()
            let status = lstat(anchor.path, &metadata)
            guard status != 0, errno == ENOENT else { throw WorkspaceSkillTargetCaptureError.unreadableDirectory }
            missing.append(anchor.lastPathComponent)
            anchor.deleteLastPathComponent()
        }
    }

    private static func identity(deviceID: WorkspaceObjectID, directory: URL) -> WorkspaceObjectID {
        var bytes = Data("agent-tooling.native-skill-directory.v1\n".utf8)
        for field in [deviceID.rawValue.uuidString.lowercased(), directory.path.precomposedStringWithCanonicalMapping] {
            let content = Data(field.utf8)
            var length = UInt64(content.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(content)
        }
        var hash = Array(SHA256.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x80
        hash[8] = (hash[8] & 0x3f) | 0x80
        return WorkspaceObjectID(UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15])))
    }
}
