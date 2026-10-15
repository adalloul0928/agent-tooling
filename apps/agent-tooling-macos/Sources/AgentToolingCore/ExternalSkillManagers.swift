import Foundation

/// Which skill folders another tool put in a client's skills folder and keeps
/// in step.
///
/// A client with no plugins of its own, like Kiro CLI, gets a package
/// manager's skills as plain folders beside the ones a person made. They look
/// loose, but they are not: the manager rewrites them on its next sync, so
/// adopting one forks it and removing one is undone. This reads the records the
/// manager leaves, never guesses from a folder's name, and says only who placed
/// a folder — not that the copy is current.
///
/// Today that manager is AIM, which leaves three records, any one of which is
/// enough:
/// - `~/.aim/state/skills/<package>-<hash>.json`, listing each skill it placed
///   per client with the package it came from;
/// - `.aim-core-skills.json` in the skills folder, listing the core skills;
/// - `.aim-managed` inside the skill's folder, naming the owner.
public struct ExternalSkillManagerIndex: Sendable, Equatable {
    /// Placed folders, by standardized absolute path, with the package each came from.
    private var placements: [String: ObservedExternalManager]

    public init(placements: [String: ObservedExternalManager] = [:]) {
        self.placements = placements
    }

    /// Reads AIM's placement records under `homeURL`. A record that is
    /// missing, oversized, or unreadable contributes nothing.
    public static func load(homeURL: URL, fileManager: FileManager = .default) -> Self {
        let directory = homeURL.appending(path: ".aim/state/skills", directoryHint: .isDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return Self()
        }
        var placements: [String: ObservedExternalManager] = [:]
        for file in entries.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .prefix(256)
        {
            guard let text = try? BoundedFileAccess.readUTF8(at: file),
                let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                let targets = root["targets"] as? [[String: Any]]
            else { continue }
            let recordPackage = root["packageName"] as? String
            for target in targets.prefix(64) {
                guard let targetRoot = target["targetRoot"] as? String, targetRoot.hasPrefix("/"),
                    let skills = target["skills"] as? [[String: Any]]
                else { continue }
                for skill in skills.prefix(BoundedFileAccess.maximumDirectoryEntries) {
                    guard let relative = skill["relativeDir"] as? String, !relative.isEmpty,
                        !relative.split(separator: "/").contains("..")
                    else { continue }
                    let path = standardized(URL(filePath: targetRoot).appending(path: relative))
                    let package = bounded(skill["sourcePackage"] as? String) ?? bounded(recordPackage)
                    placements[path] = ObservedExternalManager(tool: "AIM", package: package)
                }
            }
        }
        return Self(placements: placements)
    }

    /// Who placed the skill folder at `folder`, or nil when nothing says.
    public func manager(forSkillAt folder: URL) -> ObservedExternalManager? {
        if let placed = placements[Self.standardized(folder)] { return placed }
        // The marker inside the folder names its owner on its first line.
        let marker = folder.appending(path: ".aim-managed")
        if BoundedFileAccess.isRegularFile(marker) {
            let owner = (try? BoundedFileAccess.readUTF8(at: marker, maximumBytes: 4_096))?
                .split(whereSeparator: \.isNewline).first.map(String.init)
            return ObservedExternalManager(tool: "AIM", package: Self.bounded(owner))
        }
        // The core-skills manifest beside it lists the folders it owns.
        let manifest = folder.deletingLastPathComponent().appending(path: ".aim-core-skills.json")
        if BoundedFileAccess.isRegularFile(manifest),
            let text = try? BoundedFileAccess.readUTF8(at: manifest),
            let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let skills = root["skills"] as? [String: Any],
            skills[folder.lastPathComponent] != nil
        {
            return ObservedExternalManager(tool: "AIM", package: Self.bounded(root["owner"] as? String))
        }
        return nil
    }

    private static func standardized(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// A package name as a label: short, single-line, and never a path.
    private static func bounded(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.count <= 128,
            !value.contains("/"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }
}
