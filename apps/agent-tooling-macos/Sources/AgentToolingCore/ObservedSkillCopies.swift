import Foundation

/// One folder on this Mac that holds a copy of a skill, and the managed apps
/// that read it there.
public struct ObservedSkillCopy: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// The folder, standardized and absolute, with no trailing separator.
    public let path: String
    /// The managed apps that read this folder, in the app order. One folder
    /// can be read by more than one: Codex and Gemini CLI both read
    /// `~/.agents/skills`.
    public let readers: [ClientKind]
    /// `ToolCopyIdentity.definitionDigest` of the folder as the check read it.
    /// Nil is "not compared", never "the same".
    public let definitionDigest: String?
    /// How many files the folder holds, once the copies have been measured.
    public var fileCount: Int?
    /// When the newest file in the folder changed, once measured.
    public var changedAt: Date?

    public init(
        path: String, readers: [ClientKind], definitionDigest: String?, fileCount: Int? = nil, changedAt: Date? = nil
    ) {
        self.path = path
        self.readers = readers
        self.definitionDigest = definitionDigest
        self.fileCount = fileCount
        self.changedAt = changedAt
    }
}

/// The copies of one skill this Mac's managed apps hold, for choosing which
/// one a library takes.
public enum ObservedSkillCopies {
    /// Every folder a managed app reads a standalone copy of `declaredName`
    /// from, one entry per folder, in the app order of its first reader.
    ///
    /// A plugin's member is its plugin's, and a folder another tool placed
    /// and keeps in step is that tool's, so neither is a copy a person can
    /// choose: both are left out. An app that is not managed is not looked
    /// at.
    public static func group(
        observations: [TargetObservation], managed: Set<ClientKind>, declaredName: String
    ) -> [ObservedSkillCopy] {
        var order: [String] = []
        var readers: [String: [ClientKind]] = [:]
        var digests: [String: String] = [:]
        for client in ClientKind.allCases where managed.contains(client) {
            for observation in observations where observation.surface.client == client {
                guard let metadata = observation.skillMetadata[declaredName],
                    metadata.providerPluginID == nil, metadata.externalManager == nil,
                    metadata.path.hasPrefix("/")
                else { continue }
                let path = ProjectPath.canonical(URL(filePath: metadata.path, directoryHint: .notDirectory))
                if readers[path] == nil { order.append(path) }
                if !readers[path, default: []].contains(client) { readers[path, default: []].append(client) }
                if digests[path] == nil, let digest = metadata.definitionDigest { digests[path] = digest }
            }
        }
        return order.map { ObservedSkillCopy(path: $0, readers: readers[$0] ?? [], definitionDigest: digests[$0]) }
    }

    /// Whether the copies hold different skills. They are the same only when
    /// every copy was read and all read alike; one copy differs from nothing.
    public static func differ(_ copies: [ObservedSkillCopy]) -> Bool {
        guard copies.count > 1 else { return false }
        let digests = copies.map(\.definitionDigest)
        guard digests.allSatisfy({ $0 != nil }) else { return true }
        return Set(digests).count > 1
    }
}
