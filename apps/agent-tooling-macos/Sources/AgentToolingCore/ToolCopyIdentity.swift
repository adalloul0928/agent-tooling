import CryptoKit
import Foundation

/// When two entries in the library are the same tool to a client.
///
/// The library records one row per place a tool was found, so a skill that
/// three plugins re-ship and a package manager also copies into Kiro is five
/// rows. A client resolves a skill by the name it declares, without the plugin
/// namespace in front of it, so that name is what makes those rows one skill.
/// Whether the copies are byte-for-byte the same is a second, separate claim,
/// answered by `definitionDigest`.
public enum ToolCopyIdentity {
    /// The declared name without the `plugin:` namespace, as written.
    public static func bareName(_ declaredName: String?) -> String? {
        guard let declaredName else { return nil }
        let bare = (declaredName.split(separator: ":").last.map(String.init) ?? declaredName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bare.isEmpty ? nil : bare
    }

    /// The name a client calls a tool by: the declared name without the
    /// `plugin:` namespace a plugin's member carries, folded for comparison.
    /// Nil when nothing was declared — a display name is not an identity, and
    /// guessing from one would merge two different skills.
    public static func callableName(_ declaredName: String?) -> String? {
        guard let bare = bareName(declaredName) else { return nil }
        let folded = bare
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.isEmpty ? nil : folded
    }

    /// A digest of a skill folder that two copies share when they would
    /// behave the same.
    ///
    /// Package managers stamp each build into the definition's `metadata:`
    /// block (a build version and commit), so the same skill shipped by two
    /// packages differs only there. That block is dropped from SKILL.md before
    /// hashing; every other byte of every visible file counts, and so does each
    /// file's relative path. Hidden files are skipped: they are the manager's
    /// own markers, not part of the skill.
    ///
    /// Nil when the folder cannot be read within the bounds, which callers
    /// treat as "not compared", never as "the same".
    public static func definitionDigest(
        ofSkillAt root: URL,
        fileManager: FileManager = .default,
        maximumFiles: Int = 1_024,
        maximumBytes: Int = 64 * 1_024 * 1_024
    ) -> String? {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let files = BoundedFileAccess.relativeRegularFiles(under: resolved, fileManager: fileManager)
        guard files.contains("SKILL.md"), files.count <= maximumFiles else { return nil }
        // Sizes first, so a folder over the bound is refused before any byte
        // of it is read. Skills that bundle fonts or images run to megabytes.
        var sizes: [String: Int] = [:]
        for relative in files {
            let url = resolved.appending(path: relative)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
            sizes[relative] = size
        }
        guard sizes.values.reduce(0, +) <= maximumBytes else { return nil }
        var hasher = SHA256()
        for relative in files.sorted() {
            let url = resolved.appending(path: relative)
            if relative == "SKILL.md" {
                guard let text = try? BoundedFileAccess.readUTF8(at: url) else { return nil }
                let bytes = Data(strippingPackagingMetadata(text).utf8)
                hasher.update(data: Data("\(relative.utf8.count):\(relative)\0\(bytes.count)\0".utf8))
                hasher.update(data: bytes)
                continue
            }
            // Every other file is hashed as it is, a chunk at a time.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            hasher.update(data: Data("\(relative.utf8.count):\(relative)\0\(sizes[relative] ?? 0)\0".utf8))
            var read = 0
            while let chunk = try? handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
                read += chunk.count
                hasher.update(data: chunk)
            }
            // A file that changed size while it was read is not the file that
            // was measured, and its digest would describe neither.
            guard read == sizes[relative] else { return nil }
        }
        return hasher.finalize().lowercaseHex
    }

    /// The definition without its frontmatter's top-level `metadata:` mapping.
    ///
    /// Only that one key goes, with the lines indented under it. Everything a
    /// client reads to decide when and how to use a skill — its name,
    /// description, version, and body — is kept exactly. Text with no
    /// frontmatter is returned unchanged.
    static func strippingPackagingMetadata(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return normalized }
        var kept: [String] = []
        var skipping = false
        for line in lines[1..<end] {
            let isTopLevel = !(line.first?.isWhitespace ?? true) && !line.hasPrefix("#")
            if isTopLevel {
                skipping = line.hasPrefix("metadata:")
                if skipping { continue }
            } else if skipping, line.trimmingCharacters(in: .whitespaces).isEmpty || line.first?.isWhitespace == true {
                continue
            }
            kept.append(line)
        }
        lines.replaceSubrange(1..<end, with: kept)
        return lines.joined(separator: "\n")
    }

    /// One skill per re-shipped copy, for anything that reasons about skills
    /// rather than about where each copy sits.
    ///
    /// Recent work cannot tell copies apart — a client records that it used
    /// `agent-sop-author`, not which plugin's copy it loaded — so judging each
    /// copy separately splits one skill's evidence five ways and recommends it
    /// five times. Copies are entries with the same callable `name` (which the
    /// library's projection sets) and the same description. Two plugins that
    /// each ship a *different* skill called `review` describe them differently,
    /// so those stay apart and a reference qualified by plugin still reaches
    /// the right one.
    ///
    /// The kept entry is the one this library maintains when there is one,
    /// then the one with the most to say about itself; triggers and the apps
    /// the others were asked for in are folded into it.
    public static func collapsingCopies(_ skills: [Skill]) -> [Skill] {
        // By name first, then by description within a name. A copy whose
        // description is unknown joins the name's largest described cluster:
        // an empty summary is a gap in what was read, not a different skill.
        var nameOrder: [String] = []
        var byName: [String: [Skill]] = [:]
        for skill in skills {
            let key = callableName(skill.name).map { "name:" + $0 } ?? "id:" + skill.id
            if byName[key] == nil { nameOrder.append(key) }
            byName[key, default: []].append(skill)
        }
        var result: [Skill] = []
        for key in nameOrder {
            let named = byName[key] ?? []
            var clusterOrder: [String] = []
            var clusters: [String: [Skill]] = [:]
            var undescribed: [Skill] = []
            for skill in named {
                let description = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard !description.isEmpty else { undescribed.append(skill); continue }
                if clusters[description] == nil { clusterOrder.append(description) }
                clusters[description, default: []].append(skill)
            }
            if let largest = clusterOrder.max(by: { (clusters[$0]?.count ?? 0) < (clusters[$1]?.count ?? 0) }) {
                clusters[largest, default: []].append(contentsOf: undescribed)
            } else if !undescribed.isEmpty {
                clusterOrder.append("")
                clusters[""] = undescribed
            }
            result += clusterOrder.compactMap { clusters[$0].map(merged) }
        }
        return result
    }

    /// The best of `members`, with the others' triggers and requested apps.
    private static func merged(_ members: [Skill]) -> Skill {
        var kept = members.sorted(by: preferred)[0]
        guard members.count > 1 else { return kept }
        var triggers = kept.triggers
        for trigger in members.flatMap(\.triggers) where !triggers.contains(trigger) { triggers.append(trigger) }
        kept.triggers = triggers
        var clients = kept.clients
        for state in members.flatMap(\.clients) where !clients.contains(where: { $0.client == state.client }) {
            clients.append(state)
        }
        kept.clients = clients.sorted { $0.client.rawValue < $1.client.rawValue }
        if kept.summary.isEmpty, let summary = members.first(where: { !$0.summary.isEmpty })?.summary { kept.summary = summary }
        return kept
    }

    private static func preferred(_ lhs: Skill, _ rhs: Skill) -> Bool {
        if lhs.owned != rhs.owned { return lhs.owned }
        if lhs.filesKnown != rhs.filesKnown { return lhs.filesKnown }
        if lhs.summary.isEmpty != rhs.summary.isEmpty { return !lhs.summary.isEmpty }
        return lhs.id < rhs.id
    }
}
