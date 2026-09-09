import Foundation
import Testing

@testable import AgentToolingCore

/// Checks against the ToolHive actually installed on this Mac.
///
/// Opt-in, because a machine without `thv` would report failures that say
/// nothing about the code. Read-only: no workload is created, started,
/// stopped, or removed. What these establish is the thing the scripted
/// lifecycle tests cannot — that this build's parsers and its
/// absent-versus-failing distinction match a real ToolHive rather than a
/// fixture written from the same assumptions as the code.
///
///     AGENT_TOOLING_RUN_LIVE_TOOLHIVE=1 swift test --filter LiveToolHive
private let runsLiveToolHive =
    ProcessInfo.processInfo.environment["AGENT_TOOLING_RUN_LIVE_TOOLHIVE"] == "1"

@Suite("Live ToolHive")
struct LiveToolHiveTests {
    @Test("The real version response decodes into the fields this build reads",
          .enabled(if: runsLiveToolHive))
    func versionDecodes() async throws {
        let result = try await ToolHiveRuntimeInspection().version()
        guard case .available(let version, _) = result else {
            Issue.record("ToolHive did not report a usable version: \(result)")
            return
        }
        // Every field the model declares has to come back populated, or the
        // parser is quietly tolerating a response shape that changed.
        #expect(version.version.hasPrefix("v"))
        #expect(version.commit.count >= 7)
        #expect(!version.buildDate.isEmpty)
        #expect(version.goVersion.hasPrefix("go"))
        #expect(version.platform.contains("/"))
    }

    @Test("An installed ToolHive reports as available with the capabilities this build claims",
          .enabled(if: runsLiveToolHive))
    func providerReportsAvailable() async {
        let status = await ToolHiveMCPRuntimeProvider().status()

        #expect(status.isAvailable)
        #expect(status.capabilities.contains(.health))
        #expect(status.capabilities.contains(.logs))
        #expect(status.version?.isEmpty == false)
    }

    @Test("The real workload list decodes, whatever this Mac happens to be running",
          .enabled(if: runsLiveToolHive))
    func workloadListDecodes() async throws {
        // An empty list is a valid answer and still proves the command,
        // the exit code and the JSON shape are the ones this build expects.
        let servers = try await ToolHiveMCPRuntimeProvider().servers()

        #expect(servers.map(\.name) == servers.map(\.name).sorted())
        for server in servers {
            #expect(!server.name.isEmpty)
            #expect(!server.status.isEmpty)
        }
    }

    @Test("A workload that does not exist is a failed command, not a missing ToolHive",
          .enabled(if: runsLiveToolHive))
    func absentWorkloadIsNotAnAbsentToolHive() async throws {
        // The two are handled differently everywhere upstream: an absent
        // ToolHive offers installation, a failed command reports a
        // diagnostic. Real `thv` exits 1 here, not 127.
        let name = "agent-tooling-live-check-\(UUID().uuidString.prefix(8).lowercased())"

        let result = try await ToolHiveRuntimeInspection().status(workloadName: name)

        guard case .commandFailed(let diagnostic) = result else {
            Issue.record("Expected a failed command for an absent workload, got: \(result)")
            return
        }
        #expect(!diagnostic.isEmpty)
    }

    @Test("Planning against an absent workload is blocked rather than prepared",
          .enabled(if: runsLiveToolHive))
    func planningAnAbsentWorkloadIsBlocked() async throws {
        let name = "agent-tooling-live-check-\(UUID().uuidString.prefix(8).lowercased())"

        let result = try await ToolHiveLifecycleService().plan(workloadName: name, action: .start)

        // No plan means nothing downstream can be applied, which is the
        // property that matters: this suite must never mutate a workload.
        guard case .blocked(let outcome) = result else {
            Issue.record("A nonexistent workload produced a runnable plan: \(result)")
            return
        }
        if case .commandFailed = outcome { return }
        Issue.record("Expected a failed command for an absent workload, got: \(outcome)")
    }
}
