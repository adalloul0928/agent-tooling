import Foundation

public struct AgentPluginStdioServer: Codable, Hashable, Sendable {
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case arguments = "args"
        case environment = "env"
        case currentDirectory = "cwd"
    }
}

public struct AgentPluginHTTPServer: Codable, Hashable, Sendable {
    public var url: String
    public var headers: [String: String]

    public init(url: String, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

public typealias AgentPluginMCPServerDeclaration = AgentPluginMCPServer

public enum AgentPluginMCPServer: Hashable, Sendable {
    case stdio(AgentPluginStdioServer)
    case streamableHTTP(AgentPluginHTTPServer)
    case sse(AgentPluginHTTPServer)

    public var transport: String {
        switch self {
        case .stdio: "stdio"
        case .streamableHTTP: "streamable-http"
        case .sse: "sse"
        }
    }
}

struct AgentPluginMCPValidationIssue: Identifiable, Codable, Hashable, Sendable {
    var serverName: String
    var message: String

    init(serverName: String, message: String) {
        self.serverName = serverName
        self.message = message
    }

    var id: String { "\(serverName):\(message)" }
}

struct AgentPluginMCPLoadResult: Hashable, Sendable {
    var servers: [String: AgentPluginMCPServer]
    var issues: [AgentPluginMCPValidationIssue]

}

enum AgentPluginMCPConfigurationLoader {
    static let schemaIdentifier = "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json"

    static func load(_ data: Data, packageRoot: URL? = nil) throws -> AgentPluginMCPLoadResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentPluginMCPValidationError.invalidTopLevel("The file must contain one JSON object.")
        }
        guard Set(object.keys) == Set(["$schema", "mcpServers"]) else {
            throw AgentPluginMCPValidationError.invalidTopLevel("Only $schema and mcpServers are allowed.")
        }
        guard object["$schema"] as? String == schemaIdentifier else {
            throw AgentPluginMCPValidationError.unsupportedSchema
        }
        guard let rawServers = object["mcpServers"] as? [String: Any] else {
            throw AgentPluginMCPValidationError.invalidTopLevel("mcpServers must be an object.")
        }

        var servers: [String: AgentPluginMCPServer] = [:]
        var issues: [AgentPluginMCPValidationIssue] = []
        for name in rawServers.keys.sorted() {
            do {
                guard isValidServerName(name), let rawServer = rawServers[name] as? [String: Any] else {
                    throw AgentPluginMCPValidationError.invalidServer("The server name or value is invalid.")
                }
                servers[name] = try decodeServer(rawServer, packageRoot: packageRoot)
            } catch {
                issues.append(
                    AgentPluginMCPValidationIssue(
                        serverName: name,
                        message: error.localizedDescription
                    ))
            }
        }
        return AgentPluginMCPLoadResult(servers: servers, issues: issues)
    }

    private static func decodeServer(_ object: [String: Any], packageRoot: URL?) throws -> AgentPluginMCPServer {
        guard let transport = object["type"] as? String else {
            throw AgentPluginMCPValidationError.invalidServer("A supported transport type is required.")
        }
        switch transport {
        case "stdio":
            try requireOnlyKeys(object, allowed: ["type", "command", "args", "env", "cwd"])
            guard let command = object["command"] as? String, isValidCommand(command) else {
                throw AgentPluginMCPValidationError.invalidServer("command must be one safe executable token.")
            }
            let arguments = try stringArray(object["args"], field: "args")
            let environment = try stringDictionary(object["env"], field: "env")
            guard environment.keys.allSatisfy({ $0 != "PLUGIN_ROOT" && $0 != "PLUGIN_DATA" }) else {
                throw AgentPluginMCPValidationError.invalidServer("PLUGIN_ROOT and PLUGIN_DATA are client-owned.")
            }
            let currentDirectory = object["cwd"] as? String
            if object["cwd"] != nil {
                guard let currentDirectory, isValidCurrentDirectory(currentDirectory) else {
                    throw AgentPluginMCPValidationError.invalidServer("cwd must stay within PLUGIN_ROOT or PLUGIN_DATA.")
                }
            }
            if let packageRoot {
                guard pluginPathStaysWithinRoot(command, packageRoot: packageRoot, isCurrentDirectory: false),
                    pluginPathStaysWithinRoot(currentDirectory, packageRoot: packageRoot, isCurrentDirectory: true)
                else {
                    throw AgentPluginMCPValidationError.invalidServer("command or cwd resolves outside the plugin package.")
                }
            }
            return .stdio(
                AgentPluginStdioServer(
                    command: command,
                    arguments: arguments,
                    environment: environment,
                    currentDirectory: currentDirectory
                ))
        case "streamable-http", "sse":
            try requireOnlyKeys(object, allowed: ["type", "url", "headers"])
            guard let url = object["url"] as? String, isValidRemoteURL(url) else {
                throw AgentPluginMCPValidationError.invalidServer("url must be a safe HTTPS endpoint or loopback HTTP endpoint.")
            }
            let headers = try stringDictionary(object["headers"], field: "headers")
            try validateHeaders(headers)
            let server = AgentPluginHTTPServer(url: url, headers: headers)
            return transport == "streamable-http" ? .streamableHTTP(server) : .sse(server)
        default:
            throw AgentPluginMCPValidationError.invalidServer("Unsupported MCP transport: \(transport)")
        }
    }

    private static func requireOnlyKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw AgentPluginMCPValidationError.invalidServer("The server contains unsupported fields.")
        }
    }

    private static func stringArray(_ value: Any?, field: String) throws -> [String] {
        guard let value else { return [] }
        guard let result = value as? [String], result.allSatisfy(isSafeText) else {
            throw AgentPluginMCPValidationError.invalidServer("\(field) must contain strings without control characters.")
        }
        return result
    }

    private static func stringDictionary(_ value: Any?, field: String) throws -> [String: String] {
        guard let value else { return [:] }
        guard let result = value as? [String: String],
            result.keys.allSatisfy({ !$0.isEmpty && isSafeText($0) }),
            result.values.allSatisfy(isSafeText)
        else {
            throw AgentPluginMCPValidationError.invalidServer("\(field) must contain safe string keys and values.")
        }
        return result
    }

    private static func validateHeaders(_ headers: [String: String]) throws {
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var names: Set<String> = []
        for (name, value) in headers {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }), isSafeText(value) else {
                throw AgentPluginMCPValidationError.invalidServer("headers contain an invalid HTTP field.")
            }
            let normalized = name.lowercased()
            guard names.insert(normalized).inserted else {
                throw AgentPluginMCPValidationError.invalidServer("header names must be unique ignoring case.")
            }
            if ["authorization", "proxy-authorization"].contains(normalized)
                || normalized.contains("api-key")
                || normalized.contains("token")
                || normalized.contains("secret")
            {
                throw AgentPluginMCPValidationError.invalidServer("credentials cannot be embedded in portable headers.")
            }
        }
    }

    private static func isValidServerName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && isSafeText(value)
    }

    private static func isValidCommand(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 1_024, isSafeText(value), !value.contains(where: { $0.isWhitespace }) else {
            return false
        }
        if value.hasPrefix("./") { return isContainedRelativePath(value) }
        return !value.contains("/") && !value.contains("\\") && !value.contains("${")
    }

    private static func isValidCurrentDirectory(_ value: String) -> Bool {
        if value == "${PLUGIN_ROOT}" || value == "${PLUGIN_DATA}" { return true }
        if value.hasPrefix("${PLUGIN_ROOT}/") {
            return isContainedSuffix(String(value.dropFirst("${PLUGIN_ROOT}/".count)))
        }
        if value.hasPrefix("${PLUGIN_DATA}/") {
            return isContainedSuffix(String(value.dropFirst("${PLUGIN_DATA}/".count)))
        }
        return value.hasPrefix("./") && isContainedRelativePath(value)
    }

    private static func isContainedRelativePath(_ value: String) -> Bool {
        isContainedSuffix(String(value.dropFirst(2)))
    }

    private static func isContainedSuffix(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Discovery validates only paths rooted in the package. Bare commands use
    /// platform PATH rules, while PLUGIN_DATA is a client-managed AP5 concern.
    private static func pluginPathStaysWithinRoot(
        _ value: String?, packageRoot: URL, isCurrentDirectory: Bool
    ) -> Bool {
        guard let value else { return true }
        let relative: String?
        if value.hasPrefix("./") {
            relative = String(value.dropFirst(2))
        } else if isCurrentDirectory, value == "${PLUGIN_ROOT}" {
            relative = ""
        } else if isCurrentDirectory, value.hasPrefix("${PLUGIN_ROOT}/") {
            relative = String(value.dropFirst("${PLUGIN_ROOT}/".count))
        } else {
            return true
        }
        guard let relative else { return true }
        let root = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
        let rootPath = normalizedPath(root)
        let candidatePath = normalizedPath(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func isValidRemoteURL(_ value: String) -> Bool {
        guard value.count <= 4_096,
            let components = URLComponents(string: value),
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty
        else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func isSafeText(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum AgentPluginMCPValidationError: LocalizedError, Sendable {
    case unsupportedSchema
    case invalidTopLevel(String)
    case invalidServer(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "The MCP configuration targets an unsupported Agent Plugins schema."
        case .invalidTopLevel(let message): message
        case .invalidServer(let message): message
        }
    }
}
