import Foundation

public struct ValidatedMCPDestination: Sendable, Equatable {
    public var endpoint: String
    public var command: [String]

    public init(endpoint: String, command: [String]) {
        self.endpoint = endpoint
        self.command = command
    }
}

public enum MCPDefinitionValidator {
    public static let maximumDestinationLength = 8_192
    public static let maximumArgumentCount = 64

    public static func validate(_ value: String, transport: MCPTransport) throws -> ValidatedMCPDestination {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.count <= maximumDestinationLength,
            !trimmed.unicodeScalars.contains(where: { scalar in
                scalar.value < 0x20 && ![0x09, 0x20].contains(scalar.value)
            })
        else {
            throw MCPDefinitionValidationError.destinationTooLong
        }

        switch transport {
        case .http:
            guard let components = URLComponents(string: trimmed),
                let scheme = components.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                components.host?.isEmpty == false
            else {
                throw MCPDefinitionValidationError.invalidHTTPURL
            }
            guard components.user == nil,
                components.password == nil,
                components.query == nil,
                components.fragment == nil
            else {
                throw MCPDefinitionValidationError.sensitiveHTTPURL
            }
            return ValidatedMCPDestination(endpoint: trimmed, command: [])

        case .stdio:
            let arguments = try parseCommandLine(trimmed)
            guard arguments.first?.isEmpty == false else {
                throw MCPDefinitionValidationError.emptyCommand
            }
            guard arguments.count <= maximumArgumentCount,
                arguments.allSatisfy({
                    $0.count <= maximumDestinationLength
                        && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                })
            else {
                throw MCPDefinitionValidationError.destinationTooLong
            }
            guard !containsInlineSecret(arguments) else {
                throw MCPDefinitionValidationError.inlineSecret
            }
            return ValidatedMCPDestination(endpoint: trimmed, command: arguments)
        }
    }

    public static func parseCommandLine(_ value: String) throws -> [String] {
        enum Quote: Equatable { case single, double }
        var quote: Quote?
        var escaping = false
        var current = ""
        var result: [String] = []
        var tokenStarted = false

        for character in value {
            if escaping {
                current.append(character)
                tokenStarted = true
                escaping = false
                continue
            }
            if character == "\\", quote != .single {
                escaping = true
                tokenStarted = true
                continue
            }
            if character == "\"", quote != .single {
                quote = quote == .double ? nil : .double
                tokenStarted = true
                continue
            }
            if character == "'", quote != .double {
                quote = quote == .single ? nil : .single
                tokenStarted = true
                continue
            }
            if character.isWhitespace, quote == nil {
                if tokenStarted {
                    result.append(current)
                    current = ""
                    tokenStarted = false
                }
                continue
            }
            current.append(character)
            tokenStarted = true
        }
        guard quote == nil, !escaping else {
            throw MCPDefinitionValidationError.unterminatedQuote
        }
        if tokenStarted { result.append(current) }
        return result
    }

    public static func containsInlineSecret(_ arguments: [String]) -> Bool {
        let secretFlags = Set([
            "--api-key", "--api_key", "--apikey", "--access-token", "--auth-token", "--token", "--secret", "--password", "--client-secret",
        ])
        let secretEnvironmentNames = ["api_key", "apikey", "access_token", "auth_token", "client_secret", "password", "secret", "token"]
        for (index, argument) in arguments.enumerated() {
            let lowered = argument.lowercased()
            if secretFlags.contains(lowered), index + 1 < arguments.count { return true }
            if secretFlags.contains(where: { lowered.hasPrefix($0 + "=") }) { return true }
            if lowered.contains("authorization:bearer") || lowered.contains("authorization: bearer") { return true }
            if index + 1 < arguments.count,
                secretEnvironmentNames.contains(where: { lowered == $0 || lowered.hasSuffix("_\($0)") })
            {
                return true
            }
            if let separator = argument.firstIndex(of: "=") {
                let key = argument[..<separator].lowercased()
                if secretEnvironmentNames.contains(where: key.contains) {
                    return true
                }
            }
            if let components = URLComponents(string: argument),
                components.scheme != nil,
                components.user != nil || components.password != nil || components.query != nil
            {
                return true
            }
        }
        return false
    }
}

enum MCPDefinitionValidationError: LocalizedError, Sendable {
    case emptyCommand
    case invalidHTTPURL
    case sensitiveHTTPURL
    case inlineSecret
    case destinationTooLong
    case unterminatedQuote

    var errorDescription: String? {
        switch self {
        case .emptyCommand: "Enter the executable and any arguments for the stdio server."
        case .invalidHTTPURL: "Enter a complete http or https URL for the MCP server."
        case .sensitiveHTTPURL:
            "Do not put credentials, query tokens, or fragments in the MCP URL. Authenticate through the selected client or provider."
        case .inlineSecret:
            "Do not put API keys, tokens, passwords, or authorization headers in the server command. Use the selected client's credential flow."
        case .destinationTooLong:
            "The MCP endpoint or command is empty, contains unsupported control characters, or exceeds the safe plan limit."
        case .unterminatedQuote: "The stdio command contains an unmatched quote or trailing escape."
        }
    }
}
