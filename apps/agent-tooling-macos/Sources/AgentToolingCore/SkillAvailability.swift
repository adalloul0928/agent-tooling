import Foundation

/// Edits native user-level availability, preserving unrelated settings.
/// It never moves skill packages or rewrites plugin caches.
enum SkillAvailability {
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let detail): detail
            }
        }
    }

    struct JSONDocument {
        var root: [String: Any]

        init(_ data: Data) throws {
            if data.isEmpty {
                root = [:]
            } else {
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure.unsupported("The native settings file is not a JSON object.")
                }
                root = value
            }
        }

        func isEnabled(key: String, identifier: String) throws -> Bool {
            guard root[key] == nil || root[key] is [String: Any] else {
                throw Failure.unsupported("The native \(key) settings have an unsupported format.")
            }
            let entries = root[key] as? [String: Any] ?? [:]
            return key == "enabledPlugins" ? entries[identifier] as? Bool ?? true : entries[identifier] as? String != "off"
        }
    }

    static func json(_ data: Data, key: String, identifier: String, enabled: Bool?) throws -> (Bool, Data) {
        var document = try JSONDocument(data)
        let current = try document.isEnabled(key: key, identifier: identifier)
        guard let enabled else { return (current, data) }
        var entries = document.root[key] as? [String: Any] ?? [:]
        entries[identifier] = key == "enabledPlugins" ? enabled as Any : (enabled ? "on" : "off") as Any
        document.root[key] = entries
        return (
            current,
            try JSONSerialization.data(withJSONObject: document.root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        )
    }

    /// A settings document is parsed once for all installed skills during a refresh.
    struct CodexDocument {
        private static let incompatible = try! NSRegularExpression(
            pattern: #"(?m)^\s*(?:skills\s*\.\s*config\s*=|\[skills\.config\]|config\s*=)"#)
        private static let quotedPath = try! NSRegularExpression(pattern: #"^"(?:\\.|[^"\\])*""#)
        var lines: [String]
        private var rangesByPath: [String: [Range<Int>]] = [:]

        init(_ text: String) throws {
            // Only edit the documented array-of-tables spelling. Other valid TOML
            // encodings are left to the native editor instead of guessing at a merge.
            if text.contains("\"\"\"") || text.contains("'''") {
                throw Failure.unsupported("This Codex configuration uses multiline TOML. Use Codex's Skills controls for this file.")
            }
            guard Self.incompatible.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else {
                throw Failure.unsupported(
                    "This Codex file uses a different skill configuration format. Edit availability in Codex instead.")
            }
            lines = text.components(separatedBy: "\n")
            let headers = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            for (offset, start) in headers.enumerated() {
                let header = lines[start].split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard header == "[[skills.config]]" else { continue }
                let end = offset + 1 < headers.count ? headers[offset + 1] : lines.count
                for index in (start + 1)..<end {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("path"), let equal = line.firstIndex(of: "=") else { continue }
                    let raw = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
                    guard let range = Self.quotedPath.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))?.range,
                        let swiftRange = Range(range, in: raw),
                        let parsed = try? JSONDecoder().decode(String.self, from: Data(raw[swiftRange].utf8))
                    else {
                        throw Failure.unsupported(
                            "A Codex skill path uses unsupported TOML syntax. Use Codex's Skills controls for this file.")
                    }
                    rangesByPath[parsed, default: []].append(start..<end)
                }
            }
        }

        func match(for path: String) throws -> Range<Int>? {
            let ranges = rangesByPath[path] ?? []
            guard ranges.count <= 1 else {
                throw Failure.unsupported("Duplicate Codex skill settings need to be resolved in Codex first.")
            }
            return ranges.first
        }

        func enabledEntry(in match: Range<Int>) throws -> (index: Int, value: Bool)? {
            let entries = match.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("enabled") }
            guard entries.count <= 1 else { throw Failure.unsupported("Duplicate enabled entries in Codex skill settings.") }
            guard let index = entries.first else { return nil }
            let value = lines[index].split(separator: "#", maxSplits: 1)[0].split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)
            guard value == "true" || value == "false" else { throw Failure.unsupported("Unsupported Codex skill enabled value.") }
            return (index, value == "true")
        }

        func isEnabled(path: String) throws -> Bool {
            guard let match = try match(for: path) else { return true }
            return try enabledEntry(in: match)?.value ?? true
        }
    }

    static func codex(_ text: String, path: String, enabled: Bool?) throws -> (Bool, String) {
        var document = try CodexDocument(text)
        let current = try document.isEnabled(path: path)
        guard let enabled else { return (current, text) }
        if let match = try document.match(for: path) {
            if let entry = try document.enabledEntry(in: match) {
                document.lines[entry.index] = "enabled = \(enabled)"
            } else {
                document.lines.insert("enabled = \(enabled)", at: match.lowerBound + 1)
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let quoted = String(decoding: try encoder.encode(path), as: UTF8.self)
            document.lines.append(contentsOf: ["", "[[skills.config]]", "path = \(quoted)", "enabled = \(enabled)", ""])
        }
        return (current, document.lines.joined(separator: "\n"))
    }
}
