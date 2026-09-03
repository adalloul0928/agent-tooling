import Foundation

// MARK: - Vocabulary

/// How a project came to be listed. Everything except `pinned` is re-derived
/// from disk on every scan, so a project is a discovered thing rather than a
/// record somebody has to keep up to date.
public enum ProjectDiscoveryOrigin: String, Codable, CaseIterable, Sendable {
    case sessionIndex
    case scannedRoot
    case pinned

    public var displayName: String {
        switch self {
        case .sessionIndex: "Claude Code has run here"
        case .scannedRoot: "Found by scanning a folder"
        case .pinned: "Pinned"
        }
    }
}

/// Whether a configuration file travels with the repository or stays on this
/// Mac. Confusing the two is the footgun this section exists to expose.
public enum ProjectFileSharing: String, Codable, CaseIterable, Sendable {
    case committed
    case machineLocal

    public var displayName: String {
        switch self {
        case .committed: "Shared with the repository"
        case .machineLocal: "This Mac only"
        }
    }
}

public enum ProjectFileRole: String, Codable, CaseIterable, Sendable {
    case instructions
    case settings
    case mcpDefinitions
    case skills
    case plugins

    public var displayName: String {
        switch self {
        case .instructions: "Instructions"
        case .settings: "Settings"
        case .mcpDefinitions: "MCP servers"
        case .skills: "Skills"
        case .plugins: "Plugins"
        }
    }
}

/// One configuration location Agent Tooling knows how to recognise inside a
/// project. Presence is always checked; nothing is ever created implicitly.
public struct ProjectFileDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var relativePath: String
    public var title: String
    public var client: ClientKind?
    public var role: ProjectFileRole
    public var sharing: ProjectFileSharing
    public var isDirectory: Bool

    public var id: String { relativePath }

    public init(
        relativePath: String,
        title: String,
        client: ClientKind?,
        role: ProjectFileRole,
        sharing: ProjectFileSharing,
        isDirectory: Bool = false
    ) {
        self.relativePath = relativePath
        self.title = title
        self.client = client
        self.role = role
        self.sharing = sharing
        self.isDirectory = isDirectory
    }

    /// The recognised project configuration locations, in reading order. Only
    /// files that actually exist are ever shown, so this list describes what
    /// Agent Tooling can explain rather than what a project ought to contain.
    public static let manifest: [ProjectFileDescriptor] = [
        ProjectFileDescriptor(
            relativePath: "CLAUDE.md", title: "CLAUDE.md", client: .claude, role: .instructions, sharing: .committed),
        ProjectFileDescriptor(
            relativePath: "AGENTS.md", title: "AGENTS.md", client: nil, role: .instructions, sharing: .committed),
        ProjectFileDescriptor(
            relativePath: "GEMINI.md", title: "GEMINI.md", client: .gemini, role: .instructions, sharing: .committed),
        ProjectFileDescriptor(
            relativePath: ".mcp.json", title: "Project MCP servers", client: .claude, role: .mcpDefinitions, sharing: .committed),
        ProjectFileDescriptor(
            relativePath: ".claude/settings.json", title: "Claude project settings", client: .claude, role: .settings,
            sharing: .committed),
        ProjectFileDescriptor(
            relativePath: ".claude/settings.local.json", title: "Claude local settings", client: .claude, role: .settings,
            sharing: .machineLocal),
        ProjectFileDescriptor(
            relativePath: ".claude/skills", title: "Claude project skills", client: .claude, role: .skills, sharing: .committed,
            isDirectory: true),
        ProjectFileDescriptor(
            relativePath: ".agents/skills", title: "Portable project skills", client: .codex, role: .skills, sharing: .committed,
            isDirectory: true),
        ProjectFileDescriptor(
            relativePath: ".codex/config.toml", title: "Codex project configuration", client: .codex, role: .settings,
            sharing: .committed),
        ProjectFileDescriptor(
            relativePath: ".gemini/settings.json", title: "Gemini project settings", client: .gemini, role: .settings,
            sharing: .committed),
        ProjectFileDescriptor(
            relativePath: ".gemini/skills", title: "Gemini project skills", client: .gemini, role: .skills, sharing: .committed,
            isDirectory: true),
        ProjectFileDescriptor(
            relativePath: ".gemini/extensions", title: "Gemini project extensions", client: .gemini, role: .plugins,
            sharing: .committed, isDirectory: true),
    ]

    /// Client folders searched for additional `*.local.*` files. Anything named
    /// that way is machine-local by convention even when Agent Tooling has
    /// never heard of the specific file.
    public static let localFileSearchRoots = [".claude", ".codex", ".gemini", ".agents"]
}

public struct ProjectFilePresence: Identifiable, Hashable, Codable, Sendable {
    public var descriptor: ProjectFileDescriptor
    public var path: String
    /// `nil` for a directory or a file that could not be read; otherwise the
    /// number of entries the file contributed to this project's inventory.
    public var entryCount: Int?

    public var id: String { descriptor.relativePath }

    public init(descriptor: ProjectFileDescriptor, path: String, entryCount: Int? = nil) {
        self.descriptor = descriptor
        self.path = path
        self.entryCount = entryCount
    }
}

/// A component the project itself declares: a skill package inside the
/// repository, an MCP server in a project configuration file, or a plugin the
/// project enables.
public struct ProjectComponentRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: ComponentKind
    public var client: ClientKind?
    /// `nil` for a component Agent Tooling has scoped to this project but has
    /// not yet written into any file inside it.
    public var sharing: ProjectFileSharing?
    public var sourceRelativePath: String
    public var sourcePath: String?

    public init(
        id: String,
        name: String,
        kind: ComponentKind,
        client: ClientKind?,
        sharing: ProjectFileSharing?,
        sourceRelativePath: String,
        sourcePath: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.client = client
        self.sharing = sharing
        self.sourceRelativePath = sourceRelativePath
        self.sourcePath = sourcePath
    }
}

// MARK: - The project record

public struct DiscoveredProject: Identifiable, Hashable, Codable, Sendable {
    public var path: String
    public var name: String
    /// Checked-out branch, or a short commit for a detached head. `nil` when
    /// the folder is not a Git working tree.
    public var gitBranch: String?
    public var isDetachedHead: Bool
    public var origins: Set<ProjectDiscoveryOrigin>
    public var files: [ProjectFilePresence]
    public var skills: [ProjectComponentRecord]
    public var mcpServers: [ProjectComponentRecord]
    public var plugins: [ProjectComponentRecord]
    /// Machine-local files that no line in `.gitignore` plainly covers. This
    /// is the whole of the project's health verdict: a configuration fact,
    /// not a report on anything that runs.
    public var unlistedMachineLocalPatterns: [String]
    public var inspectedAt: Date

    public var id: String { path }
    public var isPinned: Bool { origins.contains(.pinned) }

    public init(
        path: String,
        name: String,
        gitBranch: String? = nil,
        isDetachedHead: Bool = false,
        origins: Set<ProjectDiscoveryOrigin> = [],
        files: [ProjectFilePresence] = [],
        skills: [ProjectComponentRecord] = [],
        mcpServers: [ProjectComponentRecord] = [],
        plugins: [ProjectComponentRecord] = [],
        unlistedMachineLocalPatterns: [String] = [],
        inspectedAt: Date = .now
    ) {
        self.path = path
        self.name = name
        self.gitBranch = gitBranch
        self.isDetachedHead = isDetachedHead
        self.origins = origins
        self.files = files
        self.skills = skills
        self.mcpServers = mcpServers
        self.plugins = plugins
        self.unlistedMachineLocalPatterns = unlistedMachineLocalPatterns
        self.inspectedAt = inspectedAt
    }

    /// A project with nothing of its own. It should look visibly plain in the
    /// list rather than borrowing the vocabulary of a configured one.
    public var isPlain: Bool {
        files.isEmpty && skills.isEmpty && mcpServers.isEmpty && plugins.isEmpty
    }

    public var machineLocalFiles: [ProjectFilePresence] {
        files.filter { $0.descriptor.sharing == .machineLocal }
    }

    public var committedFiles: [ProjectFilePresence] {
        files.filter { $0.descriptor.sharing == .committed }
    }

    public var instructionFileTitles: [String] {
        files.filter { $0.descriptor.role == .instructions }.map(\.descriptor.title)
    }

    /// One dot, derived only from configuration. A plain project has none:
    /// there is nothing to be healthy or unhealthy about.
    public var configurationHealth: HealthState? {
        guard !isPlain else { return nil }
        return unlistedMachineLocalPatterns.isEmpty ? .healthy : .attention
    }

    /// Compact configuration facts for the collection row. Never run status.
    public var badges: [String] {
        var values: [String] = []
        if !mcpServers.isEmpty { values.append(count(mcpServers.count, singular: "MCP server")) }
        if !skills.isEmpty { values.append(count(skills.count, singular: "skill")) }
        if !plugins.isEmpty { values.append(count(plugins.count, singular: "plugin")) }
        values.append(contentsOf: instructionFileTitles)
        guard values.isEmpty else { return values }
        // A project whose only configuration is a settings file still has to
        // say something, or a row that is not plain would read as blank.
        let committed = files.filter { $0.descriptor.role == .settings && $0.descriptor.sharing == .committed }.count
        if committed > 0 { values.append(count(committed, singular: "settings file")) }
        if !machineLocalFiles.isEmpty { values.append(count(machineLocalFiles.count, singular: "machine-local file")) }
        return values
    }

    private func count(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}

/// One spelling for a project folder. A `URL` built with a directory hint
/// keeps a trailing slash while one read from a directory listing does not, and
/// the roots stored on skills and MCP servers come from both. Comparing
/// canonical strings keeps "this project" a stable idea.
public enum ProjectPath {
    public static func canonical(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public static func canonical(_ url: URL) -> String {
        canonical(url.standardizedFileURL.path(percentEncoded: false))
    }

    /// True when a scope root recorded elsewhere in the app points at this
    /// project, whichever way it was spelled.
    public static func matches(_ storedRoot: String?, project path: String) -> Bool {
        guard let storedRoot, !storedRoot.isEmpty else { return false }
        return canonical(storedRoot) == canonical(path)
    }
}

// MARK: - Session index decoding

/// Claude Code names each folder in `~/.claude/projects` after the working
/// directory it ran in, replacing both `/` and `.` with `-`. That mapping is
/// lossy, so the original path is recovered by walking the real filesystem
/// rather than by string substitution: a candidate is only ever accepted when
/// the directory actually exists.
public struct ProjectPathResolver {
    /// Stats per path component. A recorded working directory deeper or more
    /// hyphenated than this resolves through the listing fallback instead.
    private static let maximumComponentProbes = 64

    private let fileManager: FileManager
    private var listings: [String: [String]] = [:]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public mutating func resolve(sessionIndexEntry encoded: String) -> URL? {
        guard encoded.hasPrefix("-"), encoded.count <= 1_024 else { return nil }
        var budget = 4_096
        return resolve(
            remaining: encoded.dropFirst(),
            at: URL(fileURLWithPath: "/", isDirectory: true),
            budget: &budget
        )
    }

    private mutating func resolve(remaining: Substring, at directory: URL, budget: inout Int) -> URL? {
        guard budget > 0 else { return nil }
        budget -= 1
        guard !remaining.isEmpty else { return directory }

        // A hyphen in the encoded name is either a separator or a character the
        // folder really contains, so each boundary is probed directly, longest
        // first. This costs a bounded number of stats and — unlike listing the
        // parent — cannot be defeated by a directory holding more entries than
        // a single listing returns, which would otherwise drop the project
        // silently.
        for length in Self.componentLengths(in: remaining) {
            let name = String(remaining.prefix(length))
            let child = directory.appending(path: name, directoryHint: .isDirectory)
            guard isReachableDirectory(child) else { continue }
            var rest = remaining.dropFirst(length)
            if rest.hasPrefix("-") { rest = rest.dropFirst() }
            if let resolved = resolve(remaining: rest, at: child, budget: &budget) { return resolved }
        }

        // Only a folder whose real name contains a dot needs the parent's
        // listing, because the encoding flattened that dot to a hyphen and no
        // probe above could have guessed it back.
        let candidates =
            childNames(of: directory)
            .filter { $0.contains(".") && Self.encodedComponent($0).isPrefixComponent(of: remaining) }
            .sorted { ($0.count, $1) > ($1.count, $0) }
        for name in candidates.prefix(8) {
            let child = directory.appending(path: name, directoryHint: .isDirectory)
            guard isReachableDirectory(child) else { continue }
            var rest = remaining.dropFirst(Self.encodedComponent(name).count)
            if rest.hasPrefix("-") { rest = rest.dropFirst() }
            if let resolved = resolve(remaining: rest, at: child, budget: &budget) { return resolved }
        }
        return nil
    }

    /// Candidate component lengths, longest first: the whole remainder, then
    /// each position where the encoding could have placed a separator.
    private static func componentLengths(in remaining: Substring) -> [Int] {
        var lengths: [Int] = [remaining.count]
        var index = remaining.index(before: remaining.endIndex)
        while index > remaining.startIndex {
            if remaining[index] == "-" {
                lengths.append(remaining.distance(from: remaining.startIndex, to: index))
            }
            index = remaining.index(before: index)
        }
        return Array(lengths.prefix(maximumComponentProbes))
    }

    private mutating func childNames(of directory: URL) -> [String] {
        let key = directory.path(percentEncoded: false)
        if let cached = listings[key] { return cached }
        let contents = (try? fileManager.contentsOfDirectory(atPath: key)) ?? []
        let names = Array(contents.prefix(BoundedFileAccess.maximumDirectoryEntries))
        listings[key] = names
        return names
    }

    /// `/var`, `/tmp`, and `/etc` are links to real directories, and a
    /// recorded working directory genuinely runs through them. `fileExists`
    /// follows the link, where a cached `isDirectory` resource value does not.
    private func isReachableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    static func encodedComponent(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "-")
    }
}

private extension String {
    /// A path component matches when its encoded form ends exactly on a
    /// separator, so `pumpd` never swallows the start of `pumpd-app`.
    func isPrefixComponent(of encoded: Substring) -> Bool {
        guard encoded.hasPrefix(self) else { return false }
        let rest = encoded.dropFirst(count)
        return rest.isEmpty || rest.hasPrefix("-")
    }
}

// MARK: - Discovery

public struct ProjectDiscoveryOptions: Hashable, Sendable {
    public var maximumSessionIndexEntries: Int
    public var maximumScannedChildren: Int
    public var maximumProjects: Int

    public init(
        maximumSessionIndexEntries: Int = 400,
        maximumScannedChildren: Int = 400,
        maximumProjects: Int = 500
    ) {
        self.maximumSessionIndexEntries = maximumSessionIndexEntries
        self.maximumScannedChildren = maximumScannedChildren
        self.maximumProjects = maximumProjects
    }
}

public enum ProjectDiscovery {
    /// Reads Claude Code's own session index. Regular files, dangling entries,
    /// and names that do not resolve to a directory on this Mac are ignored.
    public static func sessionIndexRoots(
        homeURL: URL,
        fileManager: FileManager = .default,
        options: ProjectDiscoveryOptions = ProjectDiscoveryOptions()
    ) -> [URL] {
        let indexURL = homeURL.appending(path: ".claude/projects", directoryHint: .isDirectory)
        let indexPath = indexURL.path(percentEncoded: false)
        guard let names = try? fileManager.contentsOfDirectory(atPath: indexPath) else { return [] }

        var resolver = ProjectPathResolver(fileManager: fileManager)
        var seen = Set<String>()
        var roots: [URL] = []
        for name in names.sorted() {
            guard roots.count < options.maximumSessionIndexEntries else { break }
            var isDirectory: ObjCBool = false
            let entryPath = indexURL.appending(path: name, directoryHint: .isDirectory).path(percentEncoded: false)
            guard fileManager.fileExists(atPath: entryPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let root = resolver.resolve(sessionIndexEntry: name) else { continue }
            guard isEligibleProjectRoot(root, homeURL: homeURL) else { continue }
            guard seen.insert(ProjectPath.canonical(root)).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    /// Immediate children of a folder such as `~/ws` that look like projects.
    public static func scannedRoots(
        under root: URL,
        fileManager: FileManager = .default,
        options: ProjectDiscoveryOptions = ProjectDiscoveryOptions()
    ) -> [URL] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: root.standardizedFileURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var roots: [URL] = []
        if isProjectDirectory(root, fileManager: fileManager) { roots.append(root.standardizedFileURL) }
        for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(options.maximumScannedChildren) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            guard isProjectDirectory(child, fileManager: fileManager) else { continue }
            roots.append(child.standardizedFileURL)
        }
        return roots
    }

    /// The home folder is not a project. Its `.claude` and `.agents` folders
    /// are exactly the user-scope installation everything else inherits from,
    /// so listing it would make every project look overridden.
    public static func isEligibleProjectRoot(_ url: URL, homeURL: URL) -> Bool {
        let candidate = ProjectPath.canonical(url)
        guard candidate != "/", !candidate.isEmpty else { return false }
        return !(ProjectPath.canonical(homeURL) + "/").hasPrefix(candidate + "/")
    }

    /// A folder counts as a project when it is a Git working tree or already
    /// holds agent configuration. Any folder the user picks by hand is
    /// accepted regardless.
    public static func isProjectDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let root = url.standardizedFileURL
        if fileManager.fileExists(atPath: root.appending(path: ".git").path(percentEncoded: false)) { return true }
        return ProjectFileDescriptor.manifest.contains { descriptor in
            fileManager.fileExists(atPath: root.appending(path: descriptor.relativePath).path(percentEncoded: false))
        }
    }

    /// Builds the full record for one project. Every value is read from disk;
    /// nothing is written and no command is run.
    public static func inspect(
        root: URL,
        origins: Set<ProjectDiscoveryOrigin>,
        fileManager: FileManager = .default
    ) -> DiscoveredProject? {
        let standardized = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }

        var files: [ProjectFilePresence] = []
        var skills: [ProjectComponentRecord] = []
        var mcpServers: [ProjectComponentRecord] = []
        var plugins: [ProjectComponentRecord] = []

        for descriptor in ProjectFileDescriptor.manifest + additionalLocalDescriptors(root: standardized, fileManager: fileManager) {
            let url = standardized.appending(path: descriptor.relativePath)
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &childIsDirectory) else { continue }
            guard childIsDirectory.boolValue == descriptor.isDirectory else { continue }

            var entryCount: Int?
            switch descriptor.role {
            case .skills:
                let found = skillRecords(in: url, descriptor: descriptor, fileManager: fileManager)
                skills.append(contentsOf: found)
                entryCount = found.count
            case .plugins where descriptor.isDirectory:
                let found = extensionRecords(in: url, descriptor: descriptor, fileManager: fileManager)
                plugins.append(contentsOf: found)
                entryCount = found.count
            case .instructions:
                entryCount = nil
            default:
                let contents = (try? BoundedFileAccess.readUTF8(at: url, maximumBytes: BoundedFileAccess.maximumConfigurationBytes)) ?? ""
                let servers = mcpRecords(from: contents, descriptor: descriptor, path: url.path(percentEncoded: false))
                let enabled = pluginRecords(from: contents, descriptor: descriptor, path: url.path(percentEncoded: false))
                mcpServers.append(contentsOf: servers)
                plugins.append(contentsOf: enabled)
                entryCount = servers.count + enabled.count
            }
            files.append(
                ProjectFilePresence(descriptor: descriptor, path: url.path(percentEncoded: false), entryCount: entryCount))
        }

        let head = gitHead(root: standardized, fileManager: fileManager)
        return DiscoveredProject(
            path: ProjectPath.canonical(standardized),
            name: standardized.lastPathComponent,
            gitBranch: head?.name,
            isDetachedHead: head?.isDetached ?? false,
            origins: origins,
            files: files,
            skills: deduplicated(skills),
            mcpServers: deduplicated(mcpServers),
            plugins: deduplicated(plugins),
            unlistedMachineLocalPatterns: ProjectGitignore.unlistedPatterns(
                for: files, root: standardized, fileManager: fileManager)
        )
    }

    // MARK: Inventory readers

    private static func additionalLocalDescriptors(root: URL, fileManager: FileManager) -> [ProjectFileDescriptor] {
        let known = Set(ProjectFileDescriptor.manifest.map(\.relativePath))
        var descriptors: [ProjectFileDescriptor] = []
        for folder in ProjectFileDescriptor.localFileSearchRoots {
            let url = root.appending(path: folder, directoryHint: .isDirectory)
            guard
                let contents = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: []
                )
            else { continue }
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(64) {
                let name = child.lastPathComponent
                guard name.contains(".local."), (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let relativePath = "\(folder)/\(name)"
                guard !known.contains(relativePath) else { continue }
                descriptors.append(
                    ProjectFileDescriptor(
                        relativePath: relativePath,
                        title: name,
                        client: client(forConfigurationFolder: folder),
                        role: .settings,
                        sharing: .machineLocal
                    ))
            }
        }
        return descriptors
    }

    private static func client(forConfigurationFolder folder: String) -> ClientKind? {
        switch folder {
        case ".claude": .claude
        case ".codex", ".agents": .codex
        case ".gemini": .gemini
        default: nil
        }
    }

    private static func skillRecords(
        in url: URL,
        descriptor: ProjectFileDescriptor,
        fileManager: FileManager
    ) -> [ProjectComponentRecord] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .prefix(BoundedFileAccess.maximumDirectoryEntries)
            .compactMap { child in
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                    BoundedFileAccess.isRegularFile(child.appending(path: "SKILL.md")),
                    let identifier = boundedIdentifier(child.lastPathComponent)
                else { return nil }
                return ProjectComponentRecord(
                    id: identifier,
                    name: displayName(for: identifier),
                    kind: .skill,
                    client: descriptor.client,
                    sharing: descriptor.sharing,
                    sourceRelativePath: "\(descriptor.relativePath)/\(identifier)",
                    sourcePath: child.path(percentEncoded: false)
                )
            }
    }

    private static func extensionRecords(
        in url: URL,
        descriptor: ProjectFileDescriptor,
        fileManager: FileManager
    ) -> [ProjectComponentRecord] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .prefix(BoundedFileAccess.maximumDirectoryEntries)
            .compactMap { child in
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                    let identifier = boundedIdentifier(child.lastPathComponent)
                else { return nil }
                return ProjectComponentRecord(
                    id: identifier,
                    name: displayName(for: identifier),
                    kind: .plugin,
                    client: descriptor.client,
                    sharing: descriptor.sharing,
                    sourceRelativePath: "\(descriptor.relativePath)/\(identifier)",
                    sourcePath: child.path(percentEncoded: false)
                )
            }
    }

    private static func mcpRecords(
        from contents: String,
        descriptor: ProjectFileDescriptor,
        path: String
    ) -> [ProjectComponentRecord] {
        var identifiers = Set<String>()
        if let data = contents.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
            collectKeys(in: root, under: ["mcpServers", "mcp_servers"], into: &identifiers)
        }
        for table in TOMLTableScanner.tablePaths(in: contents) {
            guard table.count == 2, ["mcp", "mcp_servers"].contains(table[0]) else { continue }
            if let identifier = boundedIdentifier(table[1]) { identifiers.insert(identifier) }
        }
        return identifiers.sorted().map { identifier in
            ProjectComponentRecord(
                id: identifier,
                name: identifier,
                kind: .mcpServer,
                client: descriptor.client,
                sharing: descriptor.sharing,
                sourceRelativePath: descriptor.relativePath,
                sourcePath: path
            )
        }
    }

    private static func pluginRecords(
        from contents: String,
        descriptor: ProjectFileDescriptor,
        path: String
    ) -> [ProjectComponentRecord] {
        var identifiers = Set<String>()
        if let data = contents.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
            collectKeys(in: root, under: ["enabledPlugins"], into: &identifiers)
        }
        for table in TOMLTableScanner.tablePaths(in: contents) {
            guard table.count == 2, table[0] == "plugins" else { continue }
            if let identifier = boundedIdentifier(table[1]) { identifiers.insert(identifier) }
        }
        return identifiers.sorted().map { identifier in
            ProjectComponentRecord(
                id: identifier,
                name: displayName(for: identifier),
                kind: .plugin,
                client: descriptor.client,
                sharing: descriptor.sharing,
                sourceRelativePath: descriptor.relativePath,
                sourcePath: path
            )
        }
    }

    private static func collectKeys(in object: Any, under keys: [String], into identifiers: inout Set<String>) {
        var remainingNodes = 10_000
        collectKeys(in: object, under: keys, depth: 0, remainingNodes: &remainingNodes, into: &identifiers)
    }

    private static func collectKeys(
        in object: Any,
        under keys: [String],
        depth: Int,
        remainingNodes: inout Int,
        into identifiers: inout Set<String>
    ) {
        guard depth <= 32, remainingNodes > 0 else { return }
        remainingNodes -= 1
        if let dictionary = object as? [String: Any] {
            for key in keys {
                guard let table = dictionary[key] as? [String: Any] else { continue }
                identifiers.formUnion(
                    table.keys.prefix(BoundedFileAccess.maximumDirectoryEntries).compactMap(boundedIdentifier))
            }
            for value in dictionary.values {
                collectKeys(in: value, under: keys, depth: depth + 1, remainingNodes: &remainingNodes, into: &identifiers)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectKeys(in: value, under: keys, depth: depth + 1, remainingNodes: &remainingNodes, into: &identifiers)
            }
        }
    }

    private static func deduplicated(_ records: [ProjectComponentRecord]) -> [ProjectComponentRecord] {
        var seen = Set<String>()
        var result: [ProjectComponentRecord] = []
        for record in records where seen.insert("\(record.kind.rawValue):\(record.id)").inserted {
            result.append(record)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func boundedIdentifier(_ value: String) -> String? {
        guard !value.isEmpty,
            value.count <= 256,
            !value.hasPrefix("-"),
            !value.contains("/"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }

    private static func displayName(for identifier: String) -> String {
        let name = identifier.split(separator: "@").first.map(String.init) ?? identifier
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(\.capitalized).joined(separator: " ")
    }

    // MARK: Git

    struct GitHead: Hashable, Sendable {
        var name: String
        var isDetached: Bool
    }

    /// Reads `HEAD` directly. Running `git` for a label the user only glances
    /// at would spawn a process per project on every scan.
    static func gitHead(root: URL, fileManager: FileManager = .default) -> GitHead? {
        let pointer = root.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: pointer.path(percentEncoded: false), isDirectory: &isDirectory) else { return nil }

        var gitDirectory = pointer
        if !isDirectory.boolValue {
            guard let contents = try? BoundedFileAccess.readUTF8(at: pointer, maximumBytes: 8_192) else { return nil }
            let prefix = "gitdir:"
            guard let line = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let raw = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            gitDirectory =
                raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw, isDirectory: true)
                : root.appending(path: raw, directoryHint: .isDirectory).standardizedFileURL
        }

        let headURL = gitDirectory.appending(path: "HEAD")
        guard let head = try? BoundedFileAccess.readUTF8(at: headURL, maximumBytes: 8_192) else { return nil }
        let value = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "ref: refs/heads/") {
            let branch = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty, branch.count <= 256 else { return nil }
            return GitHead(name: branch, isDetached: false)
        }
        let commit = value.prefix(40)
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { return nil }
        return GitHead(name: String(commit.prefix(7)), isDetached: true)
    }
}

// MARK: - Inherited versus overridden

public enum ProjectComponentOrigin: String, Codable, CaseIterable, Sendable {
    case inherited
    case overridden
    case projectOnly

    public var displayName: String {
        switch self {
        case .inherited: "Inherited"
        case .overridden: "Overridden here"
        case .projectOnly: "Project only"
        }
    }

    public var explanation: String {
        switch self {
        case .inherited: "Comes from this Mac. The project does not change it."
        case .overridden: "This Mac has one too; the copy inside the project takes precedence."
        case .projectOnly: "Declared inside the project. It does not exist on this Mac."
        }
    }
}

/// One inherited component as it is known outside the project.
public struct ProjectInheritedComponent: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var clients: [ClientKind]

    public init(id: String, name: String, detail: String, clients: [ClientKind] = []) {
        self.id = id
        self.name = name
        self.detail = detail
        self.clients = clients
    }
}

public struct ProjectComponentRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: ComponentKind
    public var origin: ProjectComponentOrigin
    public var detail: String
    public var clients: [ClientKind]
    public var sharing: ProjectFileSharing?
    public var sourcePath: String?
    public var sourceRelativePath: String?

    public init(
        id: String,
        name: String,
        kind: ComponentKind,
        origin: ProjectComponentOrigin,
        detail: String,
        clients: [ClientKind] = [],
        sharing: ProjectFileSharing? = nil,
        sourcePath: String? = nil,
        sourceRelativePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.origin = origin
        self.detail = detail
        self.clients = clients
        self.sharing = sharing
        self.sourcePath = sourcePath
        self.sourceRelativePath = sourceRelativePath
    }
}

/// Answers the one question the rest of the app cannot: for this project, is a
/// component inherited from this Mac, replaced by a project copy, or only ever
/// declared here?
public enum ProjectOverlay {
    public static func rows(
        kind: ComponentKind,
        inherited: [ProjectInheritedComponent],
        local: [ProjectComponentRecord]
    ) -> [ProjectComponentRow] {
        let matching = local.filter { $0.kind == kind }
        let localByID = Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [ProjectComponentRow] = []

        for record in matching {
            let match = inherited.first { $0.id == record.id }
            rows.append(
                ProjectComponentRow(
                    id: record.id,
                    name: record.name,
                    kind: kind,
                    origin: match == nil ? .projectOnly : .overridden,
                    detail: record.sourceRelativePath,
                    clients: [record.client].compactMap { $0 },
                    sharing: record.sharing,
                    sourcePath: record.sourcePath,
                    sourceRelativePath: record.sourceRelativePath
                ))
        }

        for component in inherited where localByID[component.id] == nil {
            rows.append(
                ProjectComponentRow(
                    id: component.id,
                    name: component.name,
                    kind: kind,
                    origin: .inherited,
                    detail: component.detail,
                    clients: component.clients
                ))
        }

        return rows.sorted { left, right in
            if left.origin != right.origin { return order(left.origin) < order(right.origin) }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private static func order(_ origin: ProjectComponentOrigin) -> Int {
        switch origin {
        case .overridden: 0
        case .projectOnly: 1
        case .inherited: 2
        }
    }
}

// MARK: - Machine-local hygiene

/// A reviewed, idempotent edit to a project's `.gitignore`. The plan carries
/// the exact text that will be appended so it can be shown before it is
/// written; applying it never rewrites or reorders anything already there.
public struct ProjectIgnorePlan: Hashable, Sendable {
    public var projectPath: String
    public var gitignorePath: String
    public var missingPatterns: [String]
    public var appendedText: String

    public var isSatisfied: Bool { missingPatterns.isEmpty }

    public init(projectPath: String, gitignorePath: String, missingPatterns: [String], appendedText: String) {
        self.projectPath = projectPath
        self.gitignorePath = gitignorePath
        self.missingPatterns = missingPatterns
        self.appendedText = appendedText
    }
}

public enum ProjectIgnoreError: LocalizedError, Sendable {
    case notADirectory(String)
    case symbolicLink(String)
    case tooLarge(String)
    case nothingToDo

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): "The project folder is no longer available: \(path)."
        case .symbolicLink(let path): "Refusing to write through the symbolic link at \(path)."
        case .tooLarge(let path): "The .gitignore at \(path) is too large to edit safely."
        case .nothingToDo: "Every machine-local file is already listed in .gitignore."
        }
    }
}

public enum ProjectGitignore {
    public static let header = "# Agent Tooling: machine-local agent settings"
    private static let maximumBytes = 512 * 1_024

    /// The patterns a project's machine-local files need. Directories are not
    /// ignored wholesale, because the committed files live beside them.
    public static func patterns(for project: DiscoveredProject) -> [String] {
        patterns(for: project.files)
    }

    public static func patterns(for files: [ProjectFilePresence]) -> [String] {
        files
            .filter { $0.descriptor.sharing == .machineLocal }
            .map { "/" + $0.descriptor.relativePath }
            .sorted()
    }

    /// Reads the project's `.gitignore` once and reports which machine-local
    /// files it does not cover. Used while scanning, so it never throws.
    public static func unlistedPatterns(
        for files: [ProjectFilePresence],
        root: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let wanted = patterns(for: files)
        guard !wanted.isEmpty else { return [] }
        let gitignore = root.appending(path: ".gitignore", directoryHint: .notDirectory)
        let contents = (try? currentContents(at: gitignore, fileManager: fileManager)) ?? ""
        return wanted.filter { !lists($0, in: contents) }
    }

    /// True when `.gitignore` already contains a line that plainly covers the
    /// pattern. Deliberately literal: Agent Tooling does not run `git`, so it
    /// only claims a match it can point at.
    public static func lists(_ pattern: String, in contents: String) -> Bool {
        let bare = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        let equivalents: Set<String> = [pattern, bare, "/" + bare, "**/" + bare]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if equivalents.contains(line) { return true }
            // A directory rule such as `.claude/` covers everything under it.
            if line.hasSuffix("/") {
                let folder = line.hasPrefix("/") ? String(line.dropFirst()) : line
                if bare.hasPrefix(folder) { return true }
            }
        }
        return false
    }

    public static func plan(
        for project: DiscoveredProject,
        fileManager: FileManager = .default
    ) throws -> ProjectIgnorePlan {
        let root = URL(fileURLWithPath: project.path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectIgnoreError.notADirectory(project.path)
        }
        let gitignore = root.appending(path: ".gitignore", directoryHint: .notDirectory)
        let existing = try currentContents(at: gitignore, fileManager: fileManager)
        let missing = patterns(for: project).filter { !lists($0, in: existing) }

        var appended = ""
        if !missing.isEmpty {
            var prefix = ""
            if !existing.isEmpty {
                prefix = existing.hasSuffix("\n") ? "\n" : "\n\n"
            }
            appended = prefix + header + "\n" + missing.joined(separator: "\n") + "\n"
        }
        return ProjectIgnorePlan(
            projectPath: ProjectPath.canonical(root),
            gitignorePath: gitignore.path(percentEncoded: false),
            missingPatterns: missing,
            appendedText: appended
        )
    }

    /// Appends the reviewed text. Re-running it is a no-op because the plan is
    /// recomputed from the file that is on disk right now.
    @discardableResult
    public static func apply(_ plan: ProjectIgnorePlan, fileManager: FileManager = .default) throws -> Bool {
        guard !plan.missingPatterns.isEmpty, !plan.appendedText.isEmpty else { throw ProjectIgnoreError.nothingToDo }
        let gitignore = URL(fileURLWithPath: plan.gitignorePath, isDirectory: false).standardizedFileURL
        guard gitignore.lastPathComponent == ".gitignore",
            ProjectPath.canonical(gitignore.deletingLastPathComponent()) == ProjectPath.canonical(plan.projectPath)
        else {
            throw ProjectIgnoreError.notADirectory(plan.projectPath)
        }
        let existing = try currentContents(at: gitignore, fileManager: fileManager)
        let missing = plan.missingPatterns.filter { !lists($0, in: existing) }
        guard !missing.isEmpty else { return false }

        var prefix = ""
        if !existing.isEmpty {
            prefix = existing.hasSuffix("\n") ? "\n" : "\n\n"
        }
        let updated = existing + prefix + header + "\n" + missing.joined(separator: "\n") + "\n"
        try Data(updated.utf8).write(to: gitignore, options: [.atomic])
        return true
    }

    private static func currentContents(at gitignore: URL, fileManager: FileManager) throws -> String {
        guard fileManager.fileExists(atPath: gitignore.path(percentEncoded: false)) else { return "" }
        let values = try gitignore.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw ProjectIgnoreError.symbolicLink(gitignore.path(percentEncoded: false)) }
        guard values.isRegularFile == true else { throw ProjectIgnoreError.notADirectory(gitignore.path(percentEncoded: false)) }
        guard let size = values.fileSize, size <= maximumBytes else {
            throw ProjectIgnoreError.tooLarge(gitignore.path(percentEncoded: false))
        }
        return (try? BoundedFileAccess.readUTF8(at: gitignore, maximumBytes: maximumBytes, allowSymbolicLink: false)) ?? ""
    }
}
