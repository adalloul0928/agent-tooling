import Foundation

/// Portable declaration intent. Local commands and host endpoints need a
/// separate device binding; no process, credentials or connection is created.
public enum PortableMCPConnection: Hashable, Sendable {
    case remoteHTTPS(url: String)
    case deviceBound(transport: MCPTransport)

    public var transport: MCPTransport {
        switch self { case .remoteHTTPS: .http; case .deviceBound(let transport): transport }
    }
}

extension PortableMCPConnection: Codable {
    private enum Kind: String, Codable { case remoteHTTPS, deviceBound }
    private enum CodingKeys: String, CodingKey { case kind, url, transport }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .remoteHTTPS: self = .remoteHTTPS(url: try c.decode(String.self, forKey: .url))
        case .deviceBound: self = .deviceBound(transport: try c.decode(MCPTransport.self, forKey: .transport))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remoteHTTPS(let url):
            try c.encode(Kind.remoteHTTPS, forKey: .kind); try c.encode(url, forKey: .url)
        case .deviceBound(let transport):
            try c.encode(Kind.deviceBound, forKey: .kind); try c.encode(transport, forKey: .transport)
        }
    }
}

public struct PortableMCPDefinitionRecord: Codable, Hashable, Sendable {
    public var artifactID: ArtifactID
    public var connection: PortableMCPConnection
    public init(artifactID: ArtifactID, connection: PortableMCPConnection) {
        self.artifactID = artifactID; self.connection = connection
    }
    public func validate() throws {
        if case .remoteHTTPS(let url) = connection {
            try WorkspaceMCPDefinitionValidation.validateURL(url, portable: true)
        }
    }
}

public enum DeviceMCPDestination: Hashable, Sendable {
    case httpURL(String)
    case stdio(executable: String, arguments: [String])
    public var transport: MCPTransport {
        switch self { case .httpURL: .http; case .stdio: .stdio }
    }
}

extension DeviceMCPDestination: Codable {
    private enum Kind: String, Codable { case httpURL, stdio }
    private enum CodingKeys: String, CodingKey { case kind, url, executable, arguments }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .httpURL: self = .httpURL(try c.decode(String.self, forKey: .url))
        case .stdio:
            self = .stdio(executable: try c.decode(String.self, forKey: .executable),
                          arguments: try c.decode([String].self, forKey: .arguments))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .httpURL(let url):
            try c.encode(Kind.httpURL, forKey: .kind); try c.encode(url, forKey: .url)
        case .stdio(let executable, let arguments):
            try c.encode(Kind.stdio, forKey: .kind)
            try c.encode(executable, forKey: .executable); try c.encode(arguments, forKey: .arguments)
        }
    }
}

/// Setup requirements only. These values never assert that an account is
/// authenticated or that credentials are available to a client.
public enum MCPAuthenticationRequirement: String, Codable, Hashable, Sendable {
    case none, oauth, apiKey, doppler, environment
}

public struct DeviceMCPDefinitionBinding: Codable, Hashable, Sendable {
    public var artifactID: ArtifactID
    public var destination: DeviceMCPDestination?
    public var credentialRequirementNames: [String]
    public var authenticationRequirement: MCPAuthenticationRequirement
    public var workspaceRootPath: String?
    public init(artifactID: ArtifactID, destination: DeviceMCPDestination? = nil,
                credentialRequirementNames: [String] = [],
                authenticationRequirement: MCPAuthenticationRequirement = .none,
                workspaceRootPath: String? = nil) {
        self.artifactID = artifactID; self.destination = destination
        self.credentialRequirementNames = credentialRequirementNames
        self.authenticationRequirement = authenticationRequirement
        self.workspaceRootPath = workspaceRootPath
    }
    public func validate() throws {
        switch destination {
        case .httpURL(let url): try WorkspaceMCPDefinitionValidation.validateURL(url, portable: false)
        case .stdio(let executable, let arguments):
            do { try MCPDefinitionValidator.validateCommandArguments([executable] + arguments) }
            catch { throw WorkspaceDomainValidationError.invalidField("device MCP command") }
        case nil: break
        }
        if let workspaceRootPath {
            try WorkspaceDomainValidation.requireAbsolutePath(workspaceRootPath, field: "MCP workspace root")
        }
        guard credentialRequirementNames.count <= 256,
              Set(credentialRequirementNames).count == credentialRequirementNames.count else {
            throw WorkspaceDomainValidationError.invalidField("MCP credential requirement names")
        }
        for name in credentialRequirementNames {
            // Names only, never assignments, values or credential-store contents.
            guard name.utf8.count <= 256,
                  name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
                  !SensitiveValueRedactor.containsCredentialValue(in: name) else {
                throw WorkspaceDomainValidationError.invalidField("MCP credential requirement name")
            }
        }
    }
}

enum WorkspaceMCPDefinitionValidation {
    static func validateURL(_ url: String, portable: Bool) throws {
        do {
            guard url == url.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !SensitiveValueRedactor.containsCredentialValue(in: url) else {
                throw WorkspaceDomainValidationError.invalidField("MCP URL")
            }
            _ = try MCPDefinitionValidator.validate(url, transport: .http)
            if portable {
                try WorkspaceDomainValidation.requireCredentialFreeHTTPS(url, field: "portable MCP URL")
                let host = (URLComponents(string: url)?.host?.lowercased() ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                // Portable endpoints require an explicitly reviewed DNS name.
                // All IP literals and single-label/local names use a device
                // binding. DNS can still resolve privately; this is not a
                // network-reachability or public-host assertion.
                let labels = host.split(separator: ".", omittingEmptySubsequences: false)
                guard labels.count >= 2, !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
                      !host.contains(":"), labels.allSatisfy({ !$0.isEmpty }),
                      labels.last?.range(of: "[a-z]", options: .regularExpression) != nil else {
                    throw WorkspaceDomainValidationError.invalidField("portable MCP local endpoint")
                }
            }
        } catch { throw WorkspaceDomainValidationError.invalidField("MCP URL") }
    }

    static func validatePortable(_ definitions: [PortableMCPDefinitionRecord], artifacts: [ArtifactRecord]) throws {
        guard Set(definitions.map(\.artifactID)).count == definitions.count else {
            throw WorkspaceDomainValidationError.duplicate("MCP definition")
        }
        let artifactsByID = Dictionary(grouping: artifacts, by: \.identity.id)
        for definition in definitions {
            try definition.validate()
            guard let matches = artifactsByID[definition.artifactID], matches.count == 1,
                  let artifact = matches.first, artifact.identity.kind == .mcpServer,
                  artifact.identity.parentPackageID == nil, artifact.authority == .centralPersonal,
                  artifact.contentDigest == nil else {
                throw WorkspaceDomainValidationError.missingReference("managed MCP definition artifact")
            }
        }
        let defined = Set(definitions.map(\.artifactID))
        for artifact in artifacts where artifact.identity.kind == .mcpServer
            && artifact.authority == .centralPersonal && artifact.identity.parentPackageID == nil {
            guard defined.contains(artifact.identity.id) else {
                throw WorkspaceDomainValidationError.missingReference("managed MCP definition")
            }
        }
    }

    static func validateDevice(_ bindings: [DeviceMCPDefinitionBinding],
                               definitions: [PortableMCPDefinitionRecord]?) throws {
        guard Set(bindings.map(\.artifactID)).count == bindings.count else {
            throw WorkspaceDomainValidationError.duplicate("device MCP binding")
        }
        let byID = definitions.map { Dictionary(grouping: $0, by: \.artifactID) }
        for binding in bindings {
            try binding.validate()
            guard let byID else { continue }
            guard let matches = byID[binding.artifactID], matches.count == 1, let definition = matches.first else {
                throw WorkspaceDomainValidationError.missingReference("device MCP definition")
            }
            try definition.validate()
            switch definition.connection {
            case .remoteHTTPS:
                guard binding.destination == nil else {
                    throw WorkspaceDomainValidationError.invalidField("portable MCP endpoint override")
                }
            case .deviceBound(let transport):
                guard binding.destination?.transport == transport else {
                    throw WorkspaceDomainValidationError.invalidField("device MCP transport")
                }
            }
        }
    }
}
