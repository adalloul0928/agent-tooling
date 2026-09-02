import AgentToolingCore
import Foundation

enum ToolInputError: LocalizedError, Sendable {
    case notAnObject
    case undeclaredArgument(String)
    case missing(String)
    case wrongType(String, String)
    case tooLong(String, Int)
    case unsupportedCharacters(String)
    case notInEnumeration(String, [String])
    case outOfRange(String, Int, Int)
    case invalidIdentifier(String)
    case invalidUUID(String)
    case invalidProjectRoot
    case projectRootNotAllowed
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .notAnObject: "The tool arguments must be a JSON object."
        case .undeclaredArgument(let name):
            "'\(name)' is not an argument of this tool. This server accepts only the arguments in its published schema."
        case .missing(let name): "The required argument '\(name)' is missing."
        case .wrongType(let name, let expected): "The argument '\(name)' must be \(expected)."
        case .tooLong(let name, let maximum): "The argument '\(name)' exceeds the \(maximum)-character limit."
        case .unsupportedCharacters(let name): "The argument '\(name)' contains unsupported control characters."
        case .notInEnumeration(let name, let allowed): "The argument '\(name)' must be one of: \(allowed.joined(separator: ", "))."
        case .outOfRange(let name, let minimum, let maximum): "The argument '\(name)' must be between \(minimum) and \(maximum)."
        case .invalidIdentifier(let name): "The argument '\(name)' is not a valid component identifier."
        case .invalidUUID(let name): "The argument '\(name)' must be a UUID."
        case .invalidProjectRoot:
            "'projectRoot' must be an absolute directory path without '..' segments. Agent Tooling confirms it exists at review time."
        case .projectRootNotAllowed: "'projectRoot' is only accepted when 'scope' is 'project'."
        case .unknownTool(let name): "'\(name)' is not a tool on this server."
        }
    }
}

/// Typed, bounded access to one tool call's arguments.
///
/// Every key is checked against the tool's own published schema before it is
/// read, so an argument this server did not advertise — a smuggled `home`, a
/// `workspace`, a `digest` — is refused rather than ignored. Ignoring it would
/// be almost as bad: a caller could then tell which spellings are silently
/// dropped and probe for one that is not.
struct ToolArguments {
    private let fields: [String: JSONValue]

    init(tool: ToolDefinition, params: JSONValue?) throws {
        var arguments: [String: JSONValue] = [:]
        if case .object(let container)? = params, let raw = container["arguments"] {
            guard case .object(let values) = raw else { throw ToolInputError.notAnObject }
            arguments = values
        } else if case .object = params {
            arguments = [:]
        } else if params != nil {
            throw ToolInputError.notAnObject
        }

        var declared: Set<String> = []
        if case .object(let schema) = tool.inputSchema, case .object(let properties)? = schema["properties"] {
            declared = Set(properties.keys)
        }
        for key in arguments.keys where !declared.contains(key) {
            throw ToolInputError.undeclaredArgument(key)
        }
        self.fields = arguments
    }

    func optionalString(_ name: String, maximum: Int, allowsLineBreaks: Bool = false) throws -> String? {
        guard let value = fields[name], value != .null else { return nil }
        guard case .string(let text) = value else { throw ToolInputError.wrongType(name, "a string") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximum else { throw ToolInputError.tooLong(name, maximum) }
        guard !IntegrationTextSanitizer.containsUnsupportedControlCharacter(trimmed, allowsLineBreaks: allowsLineBreaks) else {
            throw ToolInputError.unsupportedCharacters(name)
        }
        return trimmed
    }

    func requiredString(_ name: String, maximum: Int, allowsLineBreaks: Bool = false) throws -> String {
        guard let value = try optionalString(name, maximum: maximum, allowsLineBreaks: allowsLineBreaks) else {
            throw ToolInputError.missing(name)
        }
        return value
    }

    func optionalEnumeration(_ name: String, allowed: [String]) throws -> String? {
        guard let value = try optionalString(name, maximum: 64) else { return nil }
        guard allowed.contains(value) else { throw ToolInputError.notInEnumeration(name, allowed) }
        return value
    }

    func requiredEnumeration(_ name: String, allowed: [String]) throws -> String {
        guard let value = try optionalEnumeration(name, allowed: allowed) else { throw ToolInputError.missing(name) }
        return value
    }

    func optionalInteger(_ name: String, minimum: Int, maximum: Int) throws -> Int? {
        guard let value = fields[name], value != .null else { return nil }
        guard case .number(let number) = value, number == number.rounded(), number.magnitude < 1e9 else {
            throw ToolInputError.wrongType(name, "an integer")
        }
        let integer = Int(number)
        guard (minimum...maximum).contains(integer) else { throw ToolInputError.outOfRange(name, minimum, maximum) }
        return integer
    }

    func requiredUUID(_ name: String) throws -> UUID {
        let raw = try requiredString(name, maximum: 36)
        guard let value = UUID(uuidString: raw) else { throw ToolInputError.invalidUUID(name) }
        return value
    }

    func optionalUUID(_ name: String) throws -> UUID? {
        guard let raw = try optionalString(name, maximum: 36) else { return nil }
        guard let value = UUID(uuidString: raw) else { throw ToolInputError.invalidUUID(name) }
        return value
    }

    func requiredIdentifier(_ name: String) throws -> String {
        let raw = try requiredString(name, maximum: IntegrationResponseLimits.identifierMaximumCharacters)
        guard IntegrationTextSanitizer.isSafeIdentifier(raw) else { throw ToolInputError.invalidIdentifier(name) }
        return raw
    }

    /// One component per call. `targets` names which clients that single
    /// component should reach; it is not a way to submit several components.
    func requiredTargets(_ name: String = "targets") throws -> [ClientKind] {
        guard let value = fields[name], value != .null else { throw ToolInputError.missing(name) }
        guard case .array(let items) = value, !items.isEmpty, items.count <= ClientKind.allCases.count else {
            throw ToolInputError.wrongType(name, "an array of 1 to \(ClientKind.allCases.count) client names")
        }
        var names: [String] = []
        for item in items {
            guard case .string(let text) = item else { throw ToolInputError.wrongType(name, "an array of strings") }
            names.append(text)
        }
        guard let targets = IntegrationTextSanitizer.parseTargets(names.joined(separator: ",")) else {
            throw ToolInputError.notInEnumeration(name, ["codex", "claude-code", "gemini"])
        }
        return targets
    }

    func requiredScope(_ name: String = "scope") throws -> ToolingScope {
        switch try requiredEnumeration(name, allowed: ["user", "project"]) {
        case "project": .project
        default: .user
        }
    }

    /// Syntactic validation only. Nothing in this process opens the directory:
    /// a filesystem probe here would be an existence oracle, and the authoritative
    /// check already happens in the app when the reviewer builds the plan.
    func projectRoot(for scope: ToolingScope, name: String = "projectRoot") throws -> String? {
        let raw = try optionalString(name, maximum: 1_024)
        guard scope == .project else {
            guard raw == nil else { throw ToolInputError.projectRootNotAllowed }
            return nil
        }
        guard let raw else { throw ToolInputError.invalidProjectRoot }
        let standardized = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path(percentEncoded: false)
        guard raw.hasPrefix("/"),
            standardized.hasPrefix("/"),
            standardized != "/",
            !standardized.contains("/../"),
            !standardized.hasSuffix("/..")
        else { throw ToolInputError.invalidProjectRoot }
        return standardized
    }
}
