import Foundation

public enum RuntimeCapability: String, Codable, CaseIterable, Sendable {
    case directConfiguration
    case lifecycle
    case isolation
    case networkPolicy
    case secretReferences
    case health
    case logs
    case toolInventory
}

public struct MCPRuntimeStatus: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var isAvailable: Bool
    public var version: String?
    public var capabilities: Set<RuntimeCapability>
    public var detail: String

    public init(
        id: String,
        displayName: String,
        isAvailable: Bool,
        version: String? = nil,
        capabilities: Set<RuntimeCapability>,
        detail: String
    ) {
        self.id = id
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.version = version
        self.capabilities = capabilities
        self.detail = detail
    }
}

public struct MCPRuntimeServer: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var package: String
    public var status: String
    public var url: String?
    public var transport: String?
    public var group: String?
    public var isRemote: Bool

    public init(
        name: String,
        package: String,
        status: String,
        url: String? = nil,
        transport: String? = nil,
        group: String? = nil,
        isRemote: Bool = false
    ) {
        self.name = name
        self.package = package
        self.status = status
        self.url = url
        self.transport = transport
        self.group = group
        self.isRemote = isRemote
    }
}

public protocol MCPRuntimeProvider: Sendable {
    var id: String { get }
    func status() async -> MCPRuntimeStatus
    func servers() async throws -> [MCPRuntimeServer]
}

public struct DirectMCPRuntimeProvider: MCPRuntimeProvider {
    public let id = "direct"

    public init() {}

    public func status() async -> MCPRuntimeStatus {
        MCPRuntimeStatus(
            id: id,
            displayName: "Direct client configuration",
            isAvailable: true,
            capabilities: [.directConfiguration],
            detail: "Uses each client's native MCP configuration without a separate runtime."
        )
    }

    public func servers() async throws -> [MCPRuntimeServer] { [] }
}

public struct ToolHiveMCPRuntimeProvider: MCPRuntimeProvider {
    public let id = "toolhive"
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(15))) {
        self.runner = runner
    }

    public func status() async -> MCPRuntimeStatus {
        do {
            switch try await ToolHiveRuntimeInspection(runner: runner).version() {
            case .available(let version, let diagnostic):
                return MCPRuntimeStatus(id: id, displayName: "ToolHive", isAvailable: true,
                    version: version.version, capabilities: [.health, .logs],
                    detail: diagnostic ?? "Read-only workload status and log inspection available.")
            case .unavailable(let diagnostic):
                return unavailableStatus(detail: diagnostic)
            case .unsupportedResponse(let diagnostic), .commandFailed(let diagnostic):
                return MCPRuntimeStatus(id: id, displayName: "ToolHive", isAvailable: true,
                    capabilities: [], detail: diagnostic.isEmpty ? "ToolHive could not be inspected." : diagnostic)
            }
        } catch {
            return unavailableStatus(detail: error.localizedDescription)
        }
    }

    public func servers() async throws -> [MCPRuntimeServer] {
        let runtimeStatus = await status()
        return try await servers(after: runtimeStatus)
    }

    /// Reuses a refresh's version probe instead of launching the CLI twice.
    public func servers(after runtimeStatus: MCPRuntimeStatus) async throws -> [MCPRuntimeServer] {
        try Task.checkCancellation()
        guard runtimeStatus.isAvailable else { return [] }
        guard runtimeStatus.capabilities.contains(.health) else { throw MCPRuntimeError.invalidResponse }
        let result = try await runner.run(
            executable: "thv",
            arguments: ["list", "--all", "--format", "json"],
            currentDirectory: nil
        )
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw MCPRuntimeError.commandFailed(bounded(result.standardError, limit: 1_024))
        }
        guard let data = result.standardOutput.data(using: .utf8), data.count <= 1_048_576 else {
            throw MCPRuntimeError.invalidResponse
        }
        let workloads: [ToolHiveWorkload]
        do {
            workloads = try AgentToolingCoding.decoder().decode([ToolHiveWorkload].self, from: data)
        } catch {
            throw MCPRuntimeError.invalidResponse
        }
        return workloads.map { workload in
            MCPRuntimeServer(
                name: bounded(workload.name, limit: 256),
                package: bounded(workload.package, limit: 1_024),
                status: bounded(workload.status, limit: 128),
                url: workload.url.map { bounded($0, limit: 2_048) },
                transport: workload.transport.map { bounded($0, limit: 128) },
                group: workload.group.map { bounded($0, limit: 256) },
                isRemote: workload.remote ?? false
            )
        }.sorted { $0.name < $1.name }
    }

    private func unavailableStatus(detail: String) -> MCPRuntimeStatus {
        let safeDetail = SensitiveValueRedactor.redact(bounded(detail, limit: 1_024))
        return MCPRuntimeStatus(
            id: id,
            displayName: "ToolHive",
            isAvailable: false,
            capabilities: [],
            detail: safeDetail.isEmpty ? "ToolHive is not installed." : safeDetail
        )
    }

    private func bounded(_ value: String, limit: Int) -> String {
        String(SensitiveValueRedactor.redact(value).prefix(limit))
    }
}

public enum MCPRuntimeError: LocalizedError, Sendable {
    case commandFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let detail): "ToolHive could not list managed servers. \(detail)"
        case .invalidResponse: "ToolHive returned an unsupported server list."
        }
    }
}

private struct ToolHiveWorkload: Decodable {
    var name: String
    var package: String
    var url: String?
    var transport: String?
    var status: String
    var group: String?
    var remote: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, package, url, status, group, remote
        case transport = "transport_type"
    }
}
