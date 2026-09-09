import Foundation

/// Read-only inspection of a locally installed ToolHive CLI.
///
/// This type deliberately does not start, stop, update, or otherwise change a
/// ToolHive workload. A returned `status` or `health` string is evidence
/// reported by ToolHive; it is not converted into an application health claim.
public struct ToolHiveRuntimeInspection: Sendable {
    public static let maximumJSONBytes = 65_536
    public static let maximumLogCharacters = 65_536

    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(10))) {
        self.runner = runner
    }

    public func version() async throws -> ToolHiveInspectionResult<ToolHiveVersion> {
        try Task.checkCancellation()
        let output: CommandOutput
        do {
            output = try await runner.run(
                executable: "thv",
                arguments: ["version", "--format", "json"],
                currentDirectory: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(diagnostic: diagnostic(error.localizedDescription))
        }
        try Task.checkCancellation()

        guard output.status == 0 else {
            let detail = diagnostic(output.standardError)
            return output.status == 127
                ? .unavailable(diagnostic: detail)
                : .commandFailed(diagnostic: detail)
        }
        guard let data = boundedJSONData(output.standardOutput) else {
            return .unsupportedResponse(diagnostic: "ToolHive version output exceeded the inspection limit.")
        }
        do {
            let version = try AgentToolingCoding.decoder().decode(ToolHiveVersion.self, from: data)
            guard hasRequiredVersionIdentity(version) else {
                return .unsupportedResponse(diagnostic: "ToolHive returned an incomplete version response.")
            }
            return .available(sanitized(version: version), diagnostic: optionalDiagnostic(output.standardError))
        } catch {
            return .unsupportedResponse(diagnostic: "ToolHive returned an unsupported version response.")
        }
    }

    public func status(workloadName: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> {
        try validate(workloadName: workloadName)
        try Task.checkCancellation()
        let output: CommandOutput
        do {
            output = try await runner.run(
                executable: "thv",
                arguments: ["status", workloadName, "--format", "json"],
                currentDirectory: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .commandFailed(diagnostic: diagnostic(error.localizedDescription))
        }
        try Task.checkCancellation()

        guard output.status == 0 else {
            return .commandFailed(diagnostic: diagnostic(output.standardError))
        }
        guard let data = boundedJSONData(output.standardOutput) else {
            return .unsupportedResponse(diagnostic: "ToolHive status output exceeded the inspection limit.")
        }
        do {
            let value = try AgentToolingCoding.decoder().decode(ToolHiveWorkloadStatus.self, from: data)
            guard value.name == workloadName, hasRequiredStatusIdentity(value) else {
                return .unsupportedResponse(diagnostic: "ToolHive returned an incomplete or mismatched status response.")
            }
            return .available(sanitized(status: value), diagnostic: optionalDiagnostic(output.standardError))
        } catch {
            return .unsupportedResponse(diagnostic: "ToolHive returned an unsupported status response.")
        }
    }

    /// Captures a non-following point-in-time log view. It never passes
    /// ToolHive's `--follow` option, so the injected runner has bounded work.
    public func logs(
        workloadName: String,
        proxy: Bool = false,
        maximumCharacters: Int = 16_384
    ) async throws -> ToolHiveLogSnapshot {
        try validate(workloadName: workloadName)
        guard (1...Self.maximumLogCharacters).contains(maximumCharacters) else {
            throw ToolHiveRuntimeInspectionError.invalidLogLimit
        }
        try Task.checkCancellation()
        var arguments = ["logs", workloadName]
        if proxy { arguments.append("--proxy") }
        let output = try await runner.run(executable: "thv", arguments: arguments, currentDirectory: nil)
        try Task.checkCancellation()
        guard output.status == 0 else {
            throw ToolHiveRuntimeInspectionError.commandFailed(diagnostic(output.standardError))
        }

        let safeOutput = boundedAndRedacted(output.standardOutput, limit: maximumCharacters)
        let upstreamTruncated = output.standardOutput.contains("[output truncated after ")
        return ToolHiveLogSnapshot(
            workloadName: workloadName,
            isProxyLog: proxy,
            output: safeOutput.value,
            isTruncated: safeOutput.truncated || upstreamTruncated,
            diagnostic: optionalDiagnostic(output.standardError)
        )
    }

    private func boundedJSONData(_ output: String) -> Data? {
        let data = Data(output.utf8)
        return data.count <= Self.maximumJSONBytes ? data : nil
    }

    private func hasRequiredVersionIdentity(_ version: ToolHiveVersion) -> Bool {
        [version.version, version.commit, version.buildDate, version.goVersion, version.platform]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func hasRequiredStatusIdentity(_ status: ToolHiveWorkloadStatus) -> Bool {
        [status.name, status.status, status.package, status.url, status.transport]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func sanitized(version: ToolHiveVersion) -> ToolHiveVersion {
        ToolHiveVersion(
            version: boundedAndRedacted(version.version, limit: 256).value,
            commit: boundedAndRedacted(version.commit, limit: 256).value,
            buildDate: boundedAndRedacted(version.buildDate, limit: 256).value,
            goVersion: boundedAndRedacted(version.goVersion, limit: 256).value,
            platform: boundedAndRedacted(version.platform, limit: 256).value
        )
    }

    private func sanitized(status: ToolHiveWorkloadStatus) -> ToolHiveWorkloadStatus {
        ToolHiveWorkloadStatus(
            name: boundedAndRedacted(status.name, limit: 256).value,
            status: boundedAndRedacted(status.status, limit: 128).value,
            health: status.health.map { boundedAndRedacted($0, limit: 256).value },
            package: boundedAndRedacted(status.package, limit: 1_024).value,
            url: boundedAndRedacted(status.url, limit: 2_048).value,
            port: status.port,
            transport: boundedAndRedacted(status.transport, limit: 128).value,
            proxyMode: status.proxyMode.map { boundedAndRedacted($0, limit: 128).value },
            group: status.group.map { boundedAndRedacted($0, limit: 256).value },
            uptime: status.uptime.map { boundedAndRedacted($0, limit: 256).value }
        )
    }

    private func validate(workloadName: String) throws {
        // Mirrors ToolHive's `ValidateWorkloadName` grammar (ASCII letters,
        // digits, dot, underscore, hyphen; max 100 bytes), with a stricter
        // command-line boundary: a leading hyphen would be parsed as an option.
        guard !workloadName.isEmpty,
              workloadName.utf8.count <= 100,
              !workloadName.hasPrefix("-"),
              workloadName.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 95: true
                  default: false
                  }
              }) else {
            throw ToolHiveRuntimeInspectionError.invalidWorkloadName
        }
    }

    private func optionalDiagnostic(_ value: String) -> String? {
        let value = diagnostic(value)
        return value.isEmpty ? nil : value
    }

    private func diagnostic(_ value: String) -> String {
        boundedAndRedacted(value, limit: 1_024).value
    }

    private func boundedAndRedacted(_ value: String, limit: Int) -> (value: String, truncated: Bool) {
        let redacted = SensitiveValueRedactor.redact(value)
        return (String(redacted.prefix(limit)), redacted.count > limit)
    }
}

public enum ToolHiveInspectionResult<Value: Hashable & Sendable>: Hashable, Sendable {
    case available(Value, diagnostic: String?)
    case unavailable(diagnostic: String)
    case unsupportedResponse(diagnostic: String)
    case commandFailed(diagnostic: String)
}

public struct ToolHiveVersion: Codable, Hashable, Sendable {
    public var version: String
    public var commit: String
    public var buildDate: String
    public var goVersion: String
    public var platform: String

    public init(version: String, commit: String, buildDate: String, goVersion: String, platform: String) {
        self.version = version
        self.commit = commit
        self.buildDate = buildDate
        self.goVersion = goVersion
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case version, commit, platform
        case buildDate = "build_date"
        case goVersion = "go_version"
    }
}

/// Exact fields emitted by `thv status <name> --format json`. `health` stays a
/// ToolHive-reported string so callers cannot mistake a running workload for a
/// verified healthy MCP server.
public struct ToolHiveWorkloadStatus: Codable, Hashable, Sendable {
    public var name: String
    public var status: String
    public var health: String?
    public var package: String
    public var url: String
    public var port: Int
    public var transport: String
    public var proxyMode: String?
    public var group: String?
    public var uptime: String?

    public init(
        name: String,
        status: String,
        health: String? = nil,
        package: String,
        url: String,
        port: Int,
        transport: String,
        proxyMode: String? = nil,
        group: String? = nil,
        uptime: String? = nil
    ) {
        self.name = name
        self.status = status
        self.health = health
        self.package = package
        self.url = url
        self.port = port
        self.transport = transport
        self.proxyMode = proxyMode
        self.group = group
        self.uptime = uptime
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, health, package, url, port, transport, group, uptime
        case proxyMode = "proxy_mode"
    }
}

public struct ToolHiveLogSnapshot: Hashable, Sendable {
    public var workloadName: String
    public var isProxyLog: Bool
    public var output: String
    public var isTruncated: Bool
    public var diagnostic: String?

    public init(workloadName: String, isProxyLog: Bool, output: String, isTruncated: Bool, diagnostic: String? = nil) {
        self.workloadName = workloadName
        self.isProxyLog = isProxyLog
        self.output = output
        self.isTruncated = isTruncated
        self.diagnostic = diagnostic
    }
}

public enum ToolHiveRuntimeInspectionError: LocalizedError, Sendable, Equatable {
    case invalidWorkloadName
    case invalidLogLimit
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkloadName:
            return "ToolHive workload names must use ToolHive's safe workload-name grammar."
        case .invalidLogLimit:
            return "The ToolHive log limit must be between 1 and \(ToolHiveRuntimeInspection.maximumLogCharacters) characters."
        case .commandFailed(let detail):
            let detail = SensitiveValueRedactor.redact(String(detail.prefix(1_024)))
            return detail.isEmpty ? "ToolHive could not retrieve logs." : "ToolHive could not retrieve logs. \(detail)"
        }
    }
}
