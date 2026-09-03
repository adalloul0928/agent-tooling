import Foundation

/// The Projects section: discovering the folders Claude Code has run in,
/// pinning them, and reading what each one carries of its own. Split out of
/// AppModel so the model file holds shared state rather than every feature.
extension AppModel {
    // Everything the Projects section needs lives between this marker and the
    // matching end marker so it can be merged as one unit. Pins and scan roots
    // are held in the workspace key-value store rather than in
    // `WorkspaceSnapshot`, so no shared model type changes shape.

    private static let pinnedProjectsKey = "projects.pinned"
    private static let projectScanRootsKey = "projects.scan-roots"
    nonisolated private static let maximumPinnedProjects = 128
    nonisolated private static let maximumProjectScanRoots = 12

    /// Projects are derived, not registered: Claude Code's own session index,
    /// any folder the user asked to scan, and any folder pinned by hand.
    public func discoverProjects(force: Bool = false) async {
        guard !isDiscoveringProjects else { return }
        guard force || !hasDiscoveredProjects else { return }
        loadProjectPreferencesIfNeeded()
        isDiscoveringProjects = true
        let home = homeURL
        let pinned = pinnedProjectPaths
        let roots = projectScanRoots
        let discovered = await Task.detached {
            Self.inspectProjects(homeURL: home, pinnedPaths: pinned, scanRoots: roots)
        }.value
        projects = discovered
        isDiscoveringProjects = false
        hasDiscoveredProjects = true
    }

    /// Adds a folder the user chose. Choosing it pins it, because a folder
    /// Claude Code has never run in has nothing else to keep it on the list.
    public func addProject(at url: URL) async {
        loadProjectPreferencesIfNeeded()
        let path = ProjectPath.canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            presentError("That folder is no longer available.")
            return
        }
        guard ProjectDiscovery.isEligibleProjectRoot(url, homeURL: homeURL) else {
            presentError(
                "Your home folder is where this Mac's own skills, MCP servers, and plugins live. Choose a project folder inside it.")
            return
        }
        guard !pinnedProjectPaths.contains(path) else { return }
        guard pinnedProjectPaths.count < Self.maximumPinnedProjects else {
            presentError("Agent Tooling keeps at most \(Self.maximumPinnedProjects) pinned projects. Unpin one first.")
            return
        }
        guard persistProjectPreferences(pinned: (pinnedProjectPaths + [path]).sorted(), scanRoots: projectScanRoots) else { return }
        await discoverProjects(force: true)
    }

    public func setProjectPinned(_ path: String, pinned: Bool) {
        loadProjectPreferencesIfNeeded()
        let normalized = ProjectPath.canonical(path)
        var values = pinnedProjectPaths.filter { $0 != normalized }
        if pinned {
            guard values.count < Self.maximumPinnedProjects else {
                presentError("Agent Tooling keeps at most \(Self.maximumPinnedProjects) pinned projects. Unpin one first.")
                return
            }
            values.append(normalized)
        }
        guard persistProjectPreferences(pinned: values.sorted(), scanRoots: projectScanRoots) else { return }
        guard let index = projects.firstIndex(where: { $0.path == normalized }) else { return }
        if pinned {
            projects[index].origins.insert(.pinned)
        } else {
            projects[index].origins.remove(.pinned)
            if projects[index].origins.isEmpty { projects.remove(at: index) }
        }
        projects.sort(by: Self.projectOrder)
    }

    /// Unpins a project. One that is only on the list because it was pinned
    /// disappears; one Claude Code has run in stays, without the pin.
    public func forgetProject(_ path: String) {
        setProjectPinned(path, pinned: false)
    }

    public func addProjectScanRoot(at url: URL) async {
        loadProjectPreferencesIfNeeded()
        let path = ProjectPath.canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            presentError("That folder is no longer available.")
            return
        }
        guard !projectScanRoots.contains(path) else { return }
        guard projectScanRoots.count < Self.maximumProjectScanRoots else {
            presentError("Agent Tooling scans at most \(Self.maximumProjectScanRoots) folders. Remove one first.")
            return
        }
        guard persistProjectPreferences(pinned: pinnedProjectPaths, scanRoots: (projectScanRoots + [path]).sorted()) else { return }
        await discoverProjects(force: true)
    }

    public func removeProjectScanRoot(_ path: String) async {
        loadProjectPreferencesIfNeeded()
        guard projectScanRoots.contains(path) else { return }
        guard persistProjectPreferences(pinned: pinnedProjectPaths, scanRoots: projectScanRoots.filter { $0 != path }) else { return }
        await discoverProjects(force: true)
    }

    /// A read-only preview of the `.gitignore` edit, safe to call while
    /// drawing. It never reports an error; the write does.
    public func projectIgnorePlan(for project: DiscoveredProject) -> ProjectIgnorePlan? {
        try? ProjectGitignore.plan(for: project)
    }

    /// Appends reviewed lines to a project's `.gitignore`. The plan shown in
    /// the sheet carries the exact text, and applying it twice changes
    /// nothing.
    @discardableResult
    public func applyProjectIgnorePlan(_ plan: ProjectIgnorePlan) -> Bool {
        do {
            let changed = try ProjectGitignore.apply(plan)
            guard changed else { return false }
            var candidate = currentSnapshot()
            candidate.activities.insert(
                ActivityReceipt(
                    kind: .configuration,
                    title: "Machine-local settings added to .gitignore",
                    detail:
                        "Appended \(plan.missingPatterns.count) line\(plan.missingPatterns.count == 1 ? "" : "s") so local agent settings are not shared with the repository.",
                    date: .now,
                    state: .healthy,
                    affectedPaths: [plan.gitignorePath]
                ), at: 0)
            _ = commit(candidate)
            refreshProject(at: plan.projectPath)
            return true
        } catch {
            presentError(error.localizedDescription)
            return false
        }
    }

    /// Re-reads one project after a change, without rescanning everything.
    public func refreshProject(at path: String) {
        let normalized = ProjectPath.canonical(path)
        guard let index = projects.firstIndex(where: { $0.path == normalized }) else { return }
        let origins = projects[index].origins
        guard let refreshed = ProjectDiscovery.inspect(root: URL(fileURLWithPath: normalized, isDirectory: true), origins: origins)
        else {
            projects.remove(at: index)
            return
        }
        projects[index] = refreshed
    }

    private func loadProjectPreferencesIfNeeded() {
        guard !hasLoadedProjectPreferences else { return }
        hasLoadedProjectPreferences = true
        pinnedProjectPaths = (try? store.load(Self.pinnedProjectsKey, as: [String].self)) ?? []
        projectScanRoots = (try? store.load(Self.projectScanRootsKey, as: [String].self)) ?? []
    }

    private func persistProjectPreferences(pinned: [String], scanRoots: [String]) -> Bool {
        do {
            try store.save(pinned, for: Self.pinnedProjectsKey)
            try store.save(scanRoots, for: Self.projectScanRootsKey)
            pinnedProjectPaths = pinned
            projectScanRoots = scanRoots
            return true
        } catch {
            presentError("The project list could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated private static func inspectProjects(
        homeURL: URL,
        pinnedPaths: [String],
        scanRoots: [String]
    ) -> [DiscoveredProject] {
        var origins: [String: Set<ProjectDiscoveryOrigin>] = [:]
        var order: [String] = []

        func add(_ url: URL, _ origin: ProjectDiscoveryOrigin) {
            guard ProjectDiscovery.isEligibleProjectRoot(url, homeURL: homeURL) else { return }
            let key = ProjectPath.canonical(url)
            if origins[key] == nil { order.append(key) }
            origins[key, default: []].insert(origin)
        }

        for path in pinnedPaths.prefix(maximumPinnedProjects) {
            add(URL(fileURLWithPath: path, isDirectory: true), .pinned)
        }
        for root in scanRoots.prefix(maximumProjectScanRoots) {
            for url in ProjectDiscovery.scannedRoots(under: URL(fileURLWithPath: root, isDirectory: true)) {
                add(url, .scannedRoot)
            }
        }
        for url in ProjectDiscovery.sessionIndexRoots(homeURL: homeURL) {
            add(url, .sessionIndex)
        }

        return
            order
            .compactMap { path in
                ProjectDiscovery.inspect(root: URL(fileURLWithPath: path, isDirectory: true), origins: origins[path] ?? [])
            }
            .sorted(by: projectOrder)
    }

    /// Pinned first, then projects that carry configuration of their own, then
    /// the plain ones. Ordering is a configuration fact, never recency.
    nonisolated private static func projectOrder(_ left: DiscoveredProject, _ right: DiscoveredProject) -> Bool {
        if left.isPinned != right.isPinned { return left.isPinned }
        if left.isPlain != right.isPlain { return right.isPlain }
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.path < right.path
    }
}
