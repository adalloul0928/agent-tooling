import Foundation

/// The client configuration files this app may edit, and nothing else. Each
/// is one fixed path under the home folder in a format the app can rewrite
/// without losing what else is in it.
public enum ClientConfigurationFile: String, Codable, CaseIterable, Sendable {
    case claudeSettings
    case claudeGlobal
    case codexConfig
    case kiroMCP
    case kiroCLI
    case geminiSettings

    public var relativePath: String {
        switch self {
        case .claudeSettings: ".claude/settings.json"
        case .claudeGlobal: ".claude.json"
        case .codexConfig: ".codex/config.toml"
        case .kiroMCP: ".kiro/settings/mcp.json"
        case .kiroCLI: ".kiro/settings/cli.json"
        case .geminiSettings: ".gemini/settings.json"
        }
    }

    public var client: ClientKind {
        switch self {
        case .claudeSettings, .claudeGlobal: .claude
        case .codexConfig: .codex
        case .kiroMCP, .kiroCLI: .kiro
        case .geminiSettings: .gemini
        }
    }

    public var isTOML: Bool { self == .codexConfig }

    public func url(homeURL: URL) -> URL { homeURL.appending(path: relativePath) }

    /// The file a path names, if it is one of these.
    public static func matching(_ path: String, homeURL: URL) -> ClientConfigurationFile? {
        let target = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        return allCases.first { $0.url(homeURL: homeURL).standardizedFileURL.path(percentEncoded: false) == target }
    }

    /// Where a client keeps its user-level settings, for a documented key.
    public static func settings(for client: ClientKind) -> ClientConfigurationFile {
        switch client {
        case .claude: .claudeSettings
        case .codex: .codexConfig
        case .kiro: .kiroCLI
        case .gemini: .geminiSettings
        }
    }
}

// MARK: - Reading

extension ClientConfigurationFile {
    /// This file's text, read the way every client configuration file is
    /// read (see `readText(at:named:)`). Nil when there is no file.
    public func readText(homeURL: URL) throws -> String? {
        try Self.readText(at: url(homeURL: homeURL), named: relativePath)
    }

    /// A configuration file's text, read bounded by the one limit every
    /// reader of one shares, so a file over it is refused before it is loaded
    /// rather than read whole and measured afterwards. Nil when nothing is
    /// there. Over the limit throws `ConfigurationFileTooLargeError`, naming
    /// the file as `name`; a file that is there but cannot be read as text
    /// throws the read's own error, so a caller never takes it for a missing
    /// one.
    public static func readText(at url: URL, named name: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try readData(at: url, named: name)
        guard let text = String(data: data, encoding: .utf8) else { throw BoundedFileAccessError.invalidUTF8(name) }
        return text
    }

    /// A configuration file's bytes exactly as they are, under the same limit
    /// and the same refusal, for a writer that fingerprints or backs them up
    /// and for the settings reader that parses them.
    static func readData(at url: URL, named name: String) throws -> Data {
        do {
            return try BoundedFileAccess.readData(at: url, maximumBytes: BoundedFileAccess.maximumConfigurationBytes)
        } catch BoundedFileAccessError.fileTooLarge(_, let maximumBytes) {
            throw ConfigurationFileTooLargeError(path: name, maximumBytes: maximumBytes)
        }
    }
}

/// A client configuration file larger than Agent Tooling reads. Every path
/// that reads one to change it, to plan a change or to show it refuses it
/// with this error before loading it: a reviewed edit, the Settings editor
/// and the settings it shows, Checkup turning a server off, and the account
/// planner. So each says the same thing, names the file and the limit, and
/// none goes on as though the file were empty.
public struct ConfigurationFileTooLargeError: LocalizedError, Hashable, Sendable {
    /// The file, as a person would find it.
    let path: String
    let maximumBytes: Int

    public var errorDescription: String? {
        "\(path) is larger than Agent Tooling's \(Self.size(maximumBytes)) limit for a configuration file, so it was left alone."
    }

    /// A limit in the unit it is set in: whole megabytes, else kilobytes.
    static func size(_ bytes: Int) -> String {
        bytes % 1_048_576 == 0 ? "\(bytes / 1_048_576) MB" : "\(bytes / 1_024) KB"
    }
}

/// One change to one key in one of those files. Reviewed as a step, applied
/// by the engine, backed up first.
public struct ClientConfigurationEdit: Codable, Hashable, Sendable {
    public enum Value: Codable, Hashable, Sendable {
        case bool(Bool)
        case number(Double)
        case string(String)
        /// Remove the key.
        case remove
        /// Add one string to the list at the key, making the list if needed.
        case appendToList(String)
        /// Take one string out of the list at the key.
        case removeFromList(String)
        /// Add `{field: value}` to the list of objects at the key, unless an
        /// entry with exactly that one field and value is already there.
        /// JSON only: Claude Code's `deniedMcpServers` is such a list.
        case appendObjectToList(field: String, value: String)
        /// Take every `{field: value}` entry with exactly that one field and
        /// value out of the list of objects at the key. Other entries stay.
        case removeObjectFromList(field: String, value: String)

        /// "true"/"false" become booleans, a number a number, anything else
        /// a string. What the model or a person typed is never run.
        public static func parsing(_ text: String) -> Value {
            switch text.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default:
                if let number = Double(text), !text.isEmpty { return .number(number) }
                return .string(text)
            }
        }
    }

    public let file: ClientConfigurationFile
    /// Nested keys for JSON; for TOML the leading components name the table
    /// (`mcp_servers.slack`) and the last is the key.
    public let keyPath: [String]
    public let value: Value

    public init(file: ClientConfigurationFile, keyPath: [String], value: Value) {
        self.file = file
        self.keyPath = keyPath
        self.value = value
    }

    static let maximumKeyComponent = 512

    /// A key component the editor will accept: bounded, non-empty, and free
    /// of anything that could be read as structure. Project paths and plugin
    /// ids are keys too, so slashes, dots, `@`, and spaces are allowed.
    public static func isSafeKeyComponent(_ component: String) -> Bool {
        !component.isEmpty && component.count <= maximumKeyComponent
            && !component.contains(where: { $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\0" || $0 == "[" || $0 == "]" || $0 == "=" })
    }

    public var isSafe: Bool {
        !keyPath.isEmpty && keyPath.count <= 8 && keyPath.allSatisfy(Self.isSafeKeyComponent)
            && {
                switch value {
                case .string(let text), .appendToList(let text), .removeFromList(let text): return text.count <= 4_096
                case .appendObjectToList(let field, let text), .removeObjectFromList(let field, let text):
                    return !file.isTOML && Self.isSafeKeyComponent(field) && text.count <= 4_096
                default: return true
                }
            }()
    }

    /// The edit as one sentence, for a step and a receipt.
    public var summary: String {
        let key = keyPath.joined(separator: ".")
        switch value {
        case .bool(let flag): return "Set \(key) to \(flag) in \(file.relativePath)"
        case .number(let number): return "Set \(key) to \(number.formatted()) in \(file.relativePath)"
        case .string(let text): return "Set \(key) to \"\(text)\" in \(file.relativePath)"
        case .remove: return "Remove \(key) from \(file.relativePath)"
        case .appendToList(let item): return "Add \(item) to \(key) in \(file.relativePath)"
        case .removeFromList(let item): return "Take \(item) out of \(key) in \(file.relativePath)"
        case .appendObjectToList(let field, let item): return "Add {\"\(field)\": \"\(item)\"} to \(key) in \(file.relativePath)"
        case .removeObjectFromList(let field, let item): return "Take {\"\(field)\": \"\(item)\"} out of \(key) in \(file.relativePath)"
        }
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> ClientConfigurationEdit {
        try JSONDecoder().decode(ClientConfigurationEdit.self, from: Data(text.utf8))
    }
}

enum ClientConfigurationEditError: LocalizedError, Equatable, Sendable {
    case unsafeEdit
    case notAnObject(String)
    case notAList(String)
    case malformedFile(String)

    var errorDescription: String? {
        switch self {
        case .unsafeEdit: "That edit is not one this app makes."
        case .notAnObject(let key): "\(key) is not a section, so nothing can be set inside it."
        case .notAList(let key): "\(key) is not a list."
        case .malformedFile(let name): "\(name) could not be read as its own format, so it was left alone."
        }
    }
}

/// Applies an edit to a file's text. JSON is parsed and written back; TOML is
/// edited line by line so comments and everything else in the file stay.
enum ClientConfigurationEditor {
    static func apply(_ edit: ClientConfigurationEdit, to text: String) throws -> String {
        guard edit.isSafe else { throw ClientConfigurationEditError.unsafeEdit }
        return edit.file.isTOML ? try applyTOML(edit, to: text) : try applyJSON(edit, to: text)
    }

    // MARK: JSON

    static func applyJSON(_ edit: ClientConfigurationEdit, to text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var root: [String: Any]
        if trimmed.isEmpty {
            root = [:]
        } else {
            guard let data = trimmed.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClientConfigurationEditError.malformedFile(edit.file.relativePath)
            }
            root = object
        }
        root = try mutate(root, path: edit.keyPath[...], value: edit.value)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func mutate(_ object: [String: Any], path: ArraySlice<String>, value: ClientConfigurationEdit.Value) throws -> [String: Any] {
        var object = object
        guard let key = path.first else { return object }
        if path.count == 1 {
            switch value {
            case .bool(let flag): object[key] = flag
            case .number(let number): object[key] = number == number.rounded() && abs(number) < 1e15 ? Int(number) : number
            case .string(let text): object[key] = text
            case .remove: object.removeValue(forKey: key)
            case .appendToList(let item):
                if object[key] == nil { object[key] = [item]; break }
                guard var list = object[key] as? [Any] else { throw ClientConfigurationEditError.notAList(key) }
                if !list.contains(where: { ($0 as? String) == item }) { list.append(item) }
                object[key] = list
            case .removeFromList(let item):
                guard object[key] != nil else { break }
                guard let list = object[key] as? [Any] else { throw ClientConfigurationEditError.notAList(key) }
                object[key] = list.filter { ($0 as? String) != item }
            case .appendObjectToList(let field, let item):
                if object[key] == nil { object[key] = [[field: item]]; break }
                guard var list = object[key] as? [Any] else { throw ClientConfigurationEditError.notAList(key) }
                if !list.contains(where: { Self.isSingleFieldEntry($0, field: field, value: item) }) {
                    list.append([field: item])
                }
                object[key] = list
            case .removeObjectFromList(let field, let item):
                guard object[key] != nil else { break }
                guard let list = object[key] as? [Any] else { throw ClientConfigurationEditError.notAList(key) }
                object[key] = list.filter { !Self.isSingleFieldEntry($0, field: field, value: item) }
            }
            return object
        }
        let existing = object[key]
        guard existing == nil || existing is [String: Any] else { throw ClientConfigurationEditError.notAnObject(key) }
        object[key] = try mutate((existing as? [String: Any]) ?? [:], path: path.dropFirst(), value: value)
        return object
    }

    private static func isSingleFieldEntry(_ entry: Any, field: String, value: String) -> Bool {
        guard let fields = entry as? [String: Any], fields.count == 1 else { return false }
        return (fields[field] as? String) == value
    }

    // MARK: TOML

    /// Root keys live before the first table header; a table's keys live
    /// between its header and the next. A key is replaced where it is or added
    /// at the end of its table; a missing table is added at the end.
    static func applyTOML(_ edit: ClientConfigurationEdit, to text: String) throws -> String {
        let table = edit.keyPath.dropLast().joined(separator: ".")
        let key = edit.keyPath.last!
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }

        // Where the table's lines start and end.
        var start = -1
        var end = lines.count
        if table.isEmpty {
            start = -1
            end = lines.firstIndex { isHeader($0) } ?? lines.count
        } else if let headerIndex = lines.firstIndex(where: { headerName($0) == table }) {
            start = headerIndex
            end = (lines[(headerIndex + 1)...].firstIndex { isHeader($0) }) ?? lines.count
        } else {
            switch edit.value {
            case .remove, .removeFromList: return text  // nothing there to change
            default: break
            }
            if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false { lines.append("") }
            lines.append("[\(table)]")
            start = lines.count - 1
            end = lines.count
        }

        let indent = start >= 0 ? String(lines[start].prefix { $0 == " " || $0 == "\t" }) + "  " : ""
        let keyIndex = ((start + 1)..<end).first { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return line.hasPrefix(key) && line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
        switch edit.value {
        case .appendObjectToList, .removeObjectFromList:
            throw ClientConfigurationEditError.unsafeEdit
        case .remove:
            if let keyIndex { lines.remove(at: keyIndex) }
        case .appendToList(let item), .removeFromList(let item):
            let adding: Bool
            if case .appendToList = edit.value { adding = true } else { adding = false }
            var items: [String] = []
            if let keyIndex, let existing = parseInlineStringArray(lines[keyIndex]) { items = existing } else if keyIndex != nil {
                throw ClientConfigurationEditError.notAList(key)
            }
            if adding { if !items.contains(item) { items.append(item) } } else { items.removeAll { $0 == item } }
            let rendered = "\(key) = [" + items.map(tomlString).joined(separator: ", ") + "]"
            if let keyIndex { lines[keyIndex] = leadingWhitespace(lines[keyIndex]) + rendered } else { lines.insert(indent + rendered, at: insertionPoint(lines, start: start, end: end)) }
        default:
            let rendered = "\(key) = \(tomlValue(edit.value))"
            if let keyIndex { lines[keyIndex] = leadingWhitespace(lines[keyIndex]) + rendered } else {
                lines.insert(indent + rendered, at: insertionPoint(lines, start: start, end: end))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The end of a table's keys: before the blank lines that separate it
    /// from whatever follows, so a new key sits with the others.
    private static func insertionPoint(_ lines: [String], start: Int, end: Int) -> Int {
        var at = end
        while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        return at
    }

    private static func isHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    /// `[a."b c"]` and `[a.b]` both name `a.b c` / `a.b`.
    static func headerName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard isHeader(trimmed), !trimmed.hasPrefix("[[") else { return nil }
        return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func leadingWhitespace(_ line: String) -> String { String(line.prefix { $0 == " " || $0 == "\t" }) }

    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func tomlValue(_ value: ClientConfigurationEdit.Value) -> String {
        switch value {
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .string(let text): tomlString(text)
        default: ""
        }
    }

    private static func parseInlineStringArray(_ line: String) -> [String]? {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return nil }
        let inner = line[line.index(after: open)..<close]
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.filter { !$0.isEmpty }
    }
}
